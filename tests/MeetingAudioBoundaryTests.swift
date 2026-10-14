import Foundation
import AVFoundation

private final class BoundaryCapture: MeetingAudioCapturing {
    var onBuffer: ((AVAudioPCMBuffer, SpeakerSource, Double) -> Void)?
    var onActivity: (() -> Void)?
    var onError: ((String) -> Void)?
    var starts = 0, stops = 0
    func start(pid: pid_t, elapsed: Double) async throws { starts += 1 }
    func stop() async { stops += 1 }
    func emit(_ buffer: AVAudioPCMBuffer, source: SpeakerSource, time: Double) { onBuffer?(buffer, source, time) }
}

enum MeetingAudioBoundaryTests {
    /// Runs through the actual hub and a capture callback. No mic, playback or cloud.
    @MainActor static func run() async throws {
        let capture = BoundaryCapture(), hub = MeetingAudioHub(factory: { capture }), lease = hub.lease()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600
        var received: [(SpeakerSource, Double)] = []
        lease.onBuffer = { _, side, time in received.append((side, time)) }
        try await lease.start(pid: 77, elapsed: 0)
        func emit(_ side: SpeakerSource, _ time: Double) { capture.emit(buffer, source: side, time: time) }
        // Ordinary capture defaults to owner enabled without a takeover cutoff.
        emit(.me, 0); emit(.others, 0)
        precondition(received.count == 2)
        hub.setOwnerSpeechEnabled(true, minimumTime: 100)
        emit(.me, 1)
        precondition(received.count == 3, "repeated enabled state cannot invent a new cutoff")

        hub.setOwnerSpeechEnabled(false)
        emit(.me, 5); emit(.others, 5)
        precondition(received.count == 4 && received.last!.0 == .others)
        hub.setOwnerSpeechEnabled(false) // Duplicate disabled callback is harmless.
        hub.setOwnerSpeechEnabled(true, minimumTime: 10)
        emit(.me, 9.999); emit(.me, 10); emit(.me, 10.001); emit(.others, 1)
        precondition(received.count == 7)
        precondition(received[4].0 == .me && received[4].1 == 10)
        precondition(received[5].0 == .me && received[5].1 == 10.001)
        precondition(received[6].0 == .others && received[6].1 == 1)
        // Callback delivery may be current while the sample's PTS predates takeover.
        hub.setOwnerSpeechEnabled(true, minimumTime: 20)
        hub.setOwnerSpeechEnabled(true)
        emit(.me, 9); emit(.me, 11); emit(.me, .nan)
        precondition(received.count == 8 && received.last!.1 == 11,
                     "repeated enabled notifications must preserve the original cutoff")

        hub.setOwnerSpeechEnabled(false)
        emit(.me, 30); emit(.others, 30)
        precondition(received.count == 9 && received.last!.0 == .others)
        // A fresh takeover replaces the previous boundary.
        hub.setOwnerSpeechEnabled(true, minimumTime: 40)
        emit(.me, 39.999); emit(.me, 40)
        precondition(received.count == 10 && received.last!.1 == 40)
        hub.setOwnerSpeechEnabled(false)
        hub.setOwnerSpeechEnabled(true) // Default API remains usable without a timestamp.
        emit(.me, 0)
        precondition(received.count == 11 && received.last!.1 == 0)
        hub.setOwnerSpeechEnabled(false)
        hub.setOwnerSpeechEnabled(true, minimumTime: 60)
        await lease.stop()
        precondition(capture.starts == 1 && capture.stops == 1)
        emit(.me, 50)
        precondition(received.count == 11, "released subscribers must not receive late buffers")
        let next = hub.lease()
        next.onBuffer = { _, side, time in received.append((side, time)) }
        try await next.start(pid: 88, elapsed: 0)
        emit(.me, 0)
        precondition(received.count == 12 && received.last!.0 == .me && received.last!.1 == 0,
                     "a new capture clock must not inherit the previous meeting's cutoff")
        await next.stop()
        hub.setOwnerSpeechEnabled(false)
        let disabled = hub.lease()
        disabled.onBuffer = { _, side, time in received.append((side, time)) }
        try await disabled.start(pid: 99, elapsed: 0)
        emit(.me, 0); emit(.others, 0)
        precondition(received.count == 13 && received.last!.0 == .others,
                     "new capture must preserve a currently disabled owner state")
        await disabled.stop()
        precondition(capture.starts == 3 && capture.stops == 3)
        print("PASS: ownership timestamp boundary rejects queued old owner PCM; accepts equal/later frames; preserves cutoff on duplicate state; others and ordinary capture are unaffected. No physical microphone bridge delay.")
    }
}
