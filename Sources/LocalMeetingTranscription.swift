import Foundation
import AVFoundation

/// Short in-memory chunks; isolated from hold-to-talk and never polished or uploaded.
final class LocalMeetingTranscription: MeetingTranscribing, @unchecked Sendable {
    var onSegment: ((TranscriptSegment) async -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "Telos.meeting.localSpeech")
    private let writer = DispatchQueue(label: "Telos.meeting.speechInput")
    private let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converters: [SpeakerSource: AVAudioConverter] = [:]
    private var audio: [SpeakerSource: Data] = [:]
    private var starts: [SpeakerSource: Double] = [:]
    private var pending: [String: TranscriptSegment] = [:]
    private var callbacks: [Task<Void, Never>] = []
    private var process: Process?
    private var input: FileHandle?
    private var output: Pipe?
    private var bytes = Data()
    private var ready = false
    private var failed: String?
    private var accepting = true
    private let chunkBytes = 16000 * 2 * 6
    func start(localeID: String) async throws {
        guard let python = Bundle.main.object(forInfoDictionaryKey: "TelosSpeechPython") as? String,
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/meeting_speech.py") else { throw problem("Local speech runtime is missing.") }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-B", "-u", script.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["HF_HUB_OFFLINE":"1"]) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        self.process = process; self.input = input.fileHandleForWriting; self.output = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { [weak self] in self?.receive(data) }
        }
        try process.run()
        for _ in 0..<600 {
            try Task.checkCancellation()
            if queue.sync(execute: { ready }) { return }
            guard process.isRunning else { throw problem("Local speech model could not start. Check the speech model installation.") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        process.terminate(); throw problem("Local speech model took too long to load.")
    }
    func append(_ buffer: AVAudioPCMBuffer, source: SpeakerSource, time: Double) {
        queue.async { [self] in
            guard accepting, failed == nil else { return }
            if converters[source]?.inputFormat != buffer.format { converters[source] = AVAudioConverter(from: buffer.format, to: target) }
            guard let converter = converters[source], let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 64) else { fail("Could not convert mixed-language audio."); return }
            var supplied = false, error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, out in
                if supplied { out.pointee = .noDataNow; return nil }
                supplied = true; out.pointee = .haveData; return buffer
            }
            guard status != .error, let pointer = converted.int16ChannelData?[0] else { fail("Mixed-language audio conversion failed."); return }
            if starts[source] == nil { starts[source] = time }
            if let start = starts[source], abs(time - start - Double(audio[source]?.count ?? 0) / 32000) > 0.5 {
                flush(source); starts[source] = time
            }
            audio[source, default: Data()].append(Data(bytes: pointer, count: Int(converted.frameLength) * 2))
            while accepting && failed == nil && (audio[source]?.count ?? 0) >= chunkBytes { flush(source, length: chunkBytes) }
        }
    }
    private func flush(_ source: SpeakerSource, length: Int? = nil) {
        guard let data = audio[source], !data.isEmpty, let start = starts[source] else { return }
        guard pending.count < 20 else { fail("Local transcription fell behind. Capture stopped instead of silently losing speech."); return }
        let count = length ?? data.count
        let id = UUID().uuidString
        let segment = TranscriptSegment(startTime: start, endTime: start + Double(count) / 32000, speakerSource: source, text: "", isFinal: true)
        pending[id] = segment
        do {
            var request = try JSONSerialization.data(withJSONObject: ["id": id, "pcm": data.prefix(count).base64EncodedString()]); request.append(10)
            let bytes = request, handle = input
            writer.async { [weak self] in
                do { try handle?.write(contentsOf: bytes) }
                catch { self?.queue.async { [weak self] in self?.pending[id] = nil; self?.fail("Could not send audio to the local recognizer.") } }
            }
            audio[source] = Data(data.dropFirst(count)); starts[source] = segment.endTime
        } catch { pending[id] = nil; fail("Could not send audio to the local recognizer.") }
    }
    private func receive(_ data: Data) {
        bytes.append(data)
        while let newline = bytes.firstIndex(of: 10) {
            let line = Data(bytes[..<newline]); bytes.removeSubrange(...newline)
            guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if value["ready"] as? Bool == true { ready = true; continue }
            guard let id = value["id"] as? String, var segment = pending.removeValue(forKey: id) else { continue }
            if let error = value["error"] as? String { fail(error); continue }
            segment.text = value["text"] as? String ?? ""
            if !segment.text.isEmpty {
                // Finalization awaits these callbacks, so the last chunk reaches persistence.
                let callback = onSegment
                callbacks.append(Task { await callback?(segment) })
            }
        }
    }
    func finish() async {
        queue.sync {
            accepting = false
            for source in [SpeakerSource.me, .others] { flush(source) }
        }
        for _ in 0..<900 {
            if queue.sync(execute: { pending.isEmpty }) { break }
            if process?.isRunning != true { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let deliveries = queue.sync { () -> [Task<Void, Never>] in
            if !pending.isEmpty { fail("The final audio interval could not finish transcription. Earlier transcript is saved.") }
            return callbacks
        }
        for callback in deliveries { await callback.value }
        try? input?.close(); input = nil
        output?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning { process.terminate() }
        output = nil; process = nil
        queue.sync { pending.removeAll(); audio.removeAll(); callbacks.removeAll() }
    }
    private func fail(_ text: String) { guard failed == nil else { return }; failed = text; accepting = false; onError?(text) }
    private func problem(_ text: String) -> NSError { NSError(domain: "MeetingSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}
