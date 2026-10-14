import Foundation
import AVFoundation

/// One capture per Zoom meeting. ASR and the optional Pico conversation consume the same buffers.
final class MeetingAudioHub: @unchecked Sendable {
    private struct Subscriber {
        var buffer: ((AVAudioPCMBuffer, SpeakerSource, Double) -> Void)?
        var activity: (() -> Void)?
        var error: ((String) -> Void)?
    }
    private let lock = NSLock()
    private var subscribers: [UUID: Subscriber] = [:]
    private var ownerSpeechEnabled = true
    private var ownerSpeechMinimumTime: Double?
    func setOwnerSpeechEnabled(_ enabled: Bool, minimumTime: Double? = nil) {
        lock.withLock {
            if !enabled {
                ownerSpeechEnabled = false; ownerSpeechMinimumTime = nil
            } else if !ownerSpeechEnabled {
                // Capture callbacks can arrive after takeover while still carrying old PCM.
                // Use the original meeting timestamp, not callback delivery time. Repeated
                // enabled notifications must not move this boundary or admit older packets.
                ownerSpeechEnabled = true
                ownerSpeechMinimumTime = minimumTime.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            }
        }
    }
    private func shouldCapture(_ side: SpeakerSource, time: Double) -> Bool {
        lock.withLock {
            guard side == .me else { return true }
            guard ownerSpeechEnabled else { return false }
            guard let boundary = ownerSpeechMinimumTime else { return true }
            return time.isFinite && time >= boundary
        }
    }
    @MainActor private var capture: (any MeetingAudioCapturing)?
    @MainActor private var starting: Task<Void, Error>?
    @MainActor private var stopping: Task<Void, Never>?
    @MainActor private var pid: pid_t?
    private let factory: () -> any MeetingAudioCapturing
    init(factory: @escaping () -> any MeetingAudioCapturing) { self.factory = factory }
    func lease() -> MeetingAudioLease { MeetingAudioLease(hub: self) }
    private func snapshot() -> [Subscriber] { lock.lock(); defer { lock.unlock() }; return Array(subscribers.values) }
    @MainActor fileprivate func acquire(_ lease: MeetingAudioLease, pid: pid_t, elapsed: Double) async throws {
        await stopping?.value
        try Task.checkCancellation()
        guard self.pid == nil || self.pid == pid else { throw BailianMeetingTranscription.problem("Another meeting owns the audio capture.") }
        lock.withLock { subscribers[lease.id] = Subscriber(buffer: lease.onBuffer, activity: lease.onActivity, error: lease.onError) }
        if capture == nil {
            // Sample timestamps restart with each captured meeting. Keep current ownership
            // (Pico may already have disabled the owner), but never reuse the prior cutoff.
            lock.withLock { ownerSpeechMinimumTime = nil }
            let source = factory(); capture = source; self.pid = pid
            source.onBuffer = { [weak self] buffer, side, time in guard let self, self.shouldCapture(side, time: time) else { return }; self.snapshot().forEach { $0.buffer?(buffer, side, time) } }
            source.onActivity = { [weak self] in self?.snapshot().forEach { $0.activity?() } }
            source.onError = { [weak self] text in self?.snapshot().forEach { $0.error?(text) } }
            starting = Task { try await source.start(pid: pid, elapsed: elapsed) }
        }
        do { try await starting?.value; starting = nil }
        catch { await release(lease.id); throw error }
    }
    @MainActor fileprivate func release(_ id: UUID) async {
        let empty = lock.withLock { subscribers.removeValue(forKey: id); return subscribers.isEmpty }
        guard empty else { return }
        if let stopping { await stopping.value; return }
        let source = capture, task = starting
        starting = nil
        let stop = Task { [self] in
            task?.cancel(); _ = try? await task?.value; await source?.stop()
            capture = nil; pid = nil; stopping = nil
        }
        stopping = stop
        await stop.value
    }
    @MainActor func chooseMicrophone(_ uid: String) async throws {
        if #available(macOS 26, *), let source = capture as? MeetingAudioCapture { try await source.chooseMicrophone(uid) }
    }
}
final class MeetingAudioLease: MeetingAudioCapturing, @unchecked Sendable {
    fileprivate let id = UUID()
    private let hub: MeetingAudioHub
    var onBuffer: ((AVAudioPCMBuffer, SpeakerSource, Double) -> Void)?
    var onActivity: (() -> Void)?
    var onError: ((String) -> Void)?
    fileprivate init(hub: MeetingAudioHub) { self.hub = hub }
    func start(pid: pid_t, elapsed: Double) async throws { try await hub.acquire(self, pid: pid, elapsed: elapsed) }
    func stop() async { await hub.release(id) }
}
