import Foundation
import AVFoundation

/// Continuous, independently timestamped streams for the local and remote sides.
enum BailianMeetingProtocol {
    static let model = "qwen-audio-3.1-asr-flash-streaming"
    static var enabled: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "TelosBailianMeetingsEnabled") == nil
            ? DictationBailianAccount.saved.endpoint != nil : defaults.bool(forKey: "TelosBailianMeetingsEnabled")
    }
    static func message(_ action: String, id: String) -> [String: Any] {
        var payload: [String: Any] = ["input": [:]]
        if action == "run-task" {
            payload = ["task_group": "audio", "task": "asr", "function": "recognition", "model": model,
                       "input": [:], "parameters": ["format": "pcm", "sample_rate": 16000,
                       "language_hints": ["zh", "en"], "heartbeat": true,
                       "semantic_punctuation_enabled": true, "vad_model": "near_meeting_16k",
                       "vocabulary": ["Pico": 3, "Telos": 3, "Zoom": 3, "Figma": 3, "百炼": 3]]]
        }
        return ["header": ["action": action, "task_id": id, "streaming": "duplex"], "payload": payload]
    }
    static func segment(_ event: [String: Any], source: SpeakerSource, epoch: Double, receivedThrough: Double, id: UUID) -> TranscriptSegment? {
        guard let payload = event["payload"] as? [String: Any], let output = payload["output"] as? [String: Any],
              let sentence = output["sentence"] as? [String: Any], sentence["heartbeat"] as? Bool != true,
              let text = sentence["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let start = sentence["begin_time"] as? Double, start.isFinite, start >= 0 else { return nil }
        let end = (sentence["end_time"] as? Double).map { epoch + $0 / 1000 } ?? receivedThrough
        return TranscriptSegment(id: id, startTime: epoch + start / 1000, endTime: max(epoch + start / 1000, end),
                                 speakerSource: source, text: text, isFinal: sentence["sentence_end"] as? Bool == true)
    }
}

final class MeetingPCMConverter {
    private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    func convert(_ buffer: AVAudioPCMBuffer) throws -> Data {
        if converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / buffer.format.sampleRate)) + 64) else { throw URLError(.cannotDecodeContentData) }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return buffer
        }
        guard status != .error, error == nil, let samples = output.int16ChannelData?[0] else { throw URLError(.cannotDecodeContentData) }
        return Data(bytes: samples, count: Int(output.frameLength) * 2)
    }
}

final class BailianMeetingTranscription: MeetingTranscribing, @unchecked Sendable {
    var onSegment: ((TranscriptSegment) async -> Void)?
    var onError: ((String) -> Void)?
    /// Recovery notices do not mean capture should stop. A fatal error still uses onError.
    var onStatus: ((String) -> Void)?
    private let lock = NSLock()
    private var channels: [SpeakerSource: BailianMeetingChannel] = [:]
    private var starting = false
    func start(localeID: String) async throws {
        let canStart = lock.withLock { () -> Bool in
            guard channels.isEmpty && !starting else { return false }
            starting = true; return true
        }
        guard canStart else { throw Self.problem("Bailian meeting transcription is already running.") }
        defer { lock.withLock { starting = false } }
        let account = DictationBailianAccount.saved
        guard let host = account.endpoint?.host else { throw Self.problem("Configure the Bailian account in Pico Voice settings first.") }
        let key = await Task.detached { DictationBailianAccount.key(account.account) }.value
        guard let key, !key.isEmpty else { throw Self.problem("Bailian key is unavailable. Open Bailian API key… and choose Only this session.") }
        do {
            for source in [SpeakerSource.me, .others] {
                try Task.checkCancellation()
                let channel = BailianMeetingChannel(source: source,
                    onSegment: { [weak self] in await self?.onSegment?($0) },
                    onError: { [weak self] in self?.onError?($0) },
                    onStatus: { [weak self] in self?.onStatus?($0) })
                lock.withLock { channels[source] = channel }
                try await channel.start(host: host, key: key)
            }
        } catch { await finish(); throw error }
    }
    func append(_ buffer: AVAudioPCMBuffer, source: SpeakerSource, time: Double) {
        let channel = lock.withLock { channels[source] }
        channel?.append(buffer, time: time)
    }
    func finish() async {
        let ending = lock.withLock { let ending = Array(channels.values); channels.removeAll(); return ending }
        await withTaskGroup(of: Void.self) { group in
            for channel in ending { group.addTask { await channel.finish() } }
        }
    }
    #if !BAILIAN_CHANNEL_STANDALONE
    /// The caller must explicitly offer this quota-using check. It uses only a synthetic
    /// file, never the microphone, meeting capture, speakers, or a persisted credential.
    static func verifySample(_ fixture: URL, compareLocal: Bool = true) async -> [String: Any] {
        var report: [String: Any] = ["fixture": fixture.lastPathComponent, "cloudModel": BailianMeetingProtocol.model,
                                   "microphone": false, "playback": false]
        let engines: [(String, any MeetingTranscribing)] = compareLocal
            ? [("bailian", BailianMeetingTranscription()), ("local", LocalMeetingTranscription())]
            : [("bailian", BailianMeetingTranscription())]
        for (name, engine) in engines {
            let results = BailianMeetingVerificationResults(), began = ProcessInfo.processInfo.systemUptime
            engine.onSegment = { results.segment($0) }
            engine.onError = { results.error($0) }
            (engine as? BailianMeetingTranscription)?.onStatus = { results.status($0) }
            do {
                try Task.checkCancellation()
                try await engine.start(localeID: "mixed")
                let file = try AVAudioFile(forReading: fixture)
                var frames: Int64 = 0
                while file.framePosition < file.length {
                    try Task.checkCancellation()
                    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(file.processingFormat.sampleRate * 0.1))!
                    try file.read(into: buffer, frameCount: buffer.frameCapacity)
                    let position = Double(frames) / file.processingFormat.sampleRate
                    engine.append(buffer, source: .me, time: position + 1)
                    engine.append(buffer, source: .others, time: position + 2)
                    frames += Int64(buffer.frameLength)
                    try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
                }
                await engine.finish()
            } catch { results.error(error.localizedDescription); await engine.finish() }
            var value = results.report(expected: "hello world这里是阿里巴巴语音实验室")
            value["seconds"] = ProcessInfo.processInfo.systemUptime - began
            report[name] = value
            if Task.isCancelled { break }
        }
        report["complete"] = !Task.isCancelled
        return report
    }
    #endif
    static func problem(_ text: String) -> NSError { NSError(domain: "BailianMeeting", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
}

#if !BAILIAN_CHANNEL_STANDALONE
private final class BailianMeetingVerificationResults: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [TranscriptSegment] = [], errors: [String] = [], statuses: [String] = []
    func segment(_ value: TranscriptSegment) {
        lock.withLock { segments.removeAll { $0.id == value.id }; segments.append(value) }
    }
    func error(_ text: String) { lock.withLock { errors.append(text) } }
    func status(_ text: String) { lock.withLock { statuses.append(text) } }
    func report(expected: String) -> [String: Any] {
        lock.withLock {
            let finals = segments.filter(\.isFinal).sorted { $0.startTime < $1.startTime }
            var channels: [[String: Any]] = []
            for source in [SpeakerSource.me, .others] {
                let values = finals.filter { $0.speakerSource == source }
                let text = values.map(\.text).joined()
                let normalized = Self.normalized(text), reference = Self.normalized(expected)
                channels.append(["source": source.rawValue, "text": text,
                    "normalizedCharacterErrorRate": Double(Self.distance(normalized, reference)) / Double(max(1, reference.count)),
                    "essentialWords": ["helloworld", "阿里巴巴", "语音实验室"].allSatisfy { normalized.contains($0) },
                    "validTimestamps": !values.isEmpty && values.allSatisfy { $0.startTime.isFinite && $0.endTime.isFinite && $0.endTime >= $0.startTime && $0.startTime >= (source == .me ? 1 : 2) }])
            }
            let passed = errors.isEmpty && channels.allSatisfy { $0["essentialWords"] as? Bool == true && $0["validTimestamps"] as? Bool == true }
            return ["channels": channels, "segments": segments.map { ["source": $0.speakerSource.rawValue, "text": $0.text,
                "start": $0.startTime, "end": $0.endTime, "final": $0.isFinal] as [String: Any] },
                "errors": errors, "statuses": statuses, "passed": passed,
                "accuracyScope": "Short synthetic Chinese-English sample only; no claim of general meeting accuracy."]
        }
    }
    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
    private static func distance(_ text: String, _ reference: String) -> Int {
        let left = Array(text), right = Array(reference)
        var row = Array(0...right.count)
        for (i, lhs) in left.enumerated() {
            var next = [i + 1]
            for (j, rhs) in right.enumerated() { next.append(min(row[j + 1] + 1, next[j] + 1, row[j] + (lhs == rhs ? 0 : 1))) }
            row = next
        }
        return row[right.count]
    }
}
#endif

/// A transport seam permits failure, silence and late-message tests without any credentials.
protocol BailianMeetingTransport: AnyObject, Sendable {
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}
private final class BailianMeetingWebSocket: NSObject, BailianMeetingTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask!
    init(request: URLRequest) {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1_000_000
        socket.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func send(_ message: URLSessionWebSocketTask.Message) async throws { try await socket.send(message) }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await socket.receive() }
    func cancel() { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
}

/// Every PCM packet carries its position on the original meeting clock, including across reconnects.
struct BailianMeetingPacket {
    var data: Data
    var time: Double
    var end: Double { time + Double(data.count / 2) / 16000 }
    var isSilence: Bool { data.allSatisfy { $0 == 0 } }
    func after(_ boundary: Double) -> Self? {
        if boundary == -Double.infinity || boundary <= time + 0.00001 { return self }
        guard boundary.isFinite, boundary < end else { return nil }
        let skipped = max(0, min(data.count / 2, Int(((boundary - time) * 16000 - 0.000001).rounded(.up))))
        guard skipped < data.count / 2 else { return nil }
        return Self(data: Data(data.dropFirst(skipped * 2)), time: time + Double(skipped) / 16000)
    }
}

final class BailianMeetingChannel: @unchecked Sendable {
    let source: SpeakerSource
    private let onSegment: (TranscriptSegment) async -> Void
    private let onError: (String) -> Void
    private let onStatus: (String) -> Void
    private let makeTransport: (URLRequest) -> any BailianMeetingTransport
    private let queue = DispatchQueue(label: "Telos.meeting.bailian.channel")
    private let converter = MeetingPCMConverter()
    private var transport: (any BailianMeetingTransport)?
    private var sender: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var heartbeat: DispatchSourceTimer?
    private var output: AsyncStream<URLSessionWebSocketTask.Message>.Continuation?
    private var request: URLRequest?
    private var generation = UUID()
    private var taskID = ""
    private var ready = false, closed = false, accepting = true, done = false, finishing = false
    private var everReady = false
    private var failure: String?
    private var attempt = 0
    private var pendingBytes = 0
    private var connectionEpoch: Double?
    private var connectionSamples = 0
    private var through: Double?
    private var anchor: (time: Double, uptime: Double)?
    private var confirmedThrough = -Double.infinity
    private var discardedThrough = -Double.infinity
    private var history: [BailianMeetingPacket] = []
    private var sentenceIDs: [String: UUID] = [:]
    private let startupSeconds: Double
    private let retryDelay: Double
    private let maxPendingBytes = 16000 * 2 * 45
    init(source: SpeakerSource, onSegment: @escaping (TranscriptSegment) async -> Void,
         onError: @escaping (String) -> Void, onStatus: @escaping (String) -> Void = { _ in },
         startupSeconds: Double = 20, retryDelay: Double = 0.8,
         makeTransport: @escaping (URLRequest) -> any BailianMeetingTransport = { BailianMeetingWebSocket(request: $0) }) {
        self.source = source; self.onSegment = onSegment; self.onError = onError; self.onStatus = onStatus
        self.startupSeconds = startupSeconds; self.retryDelay = retryDelay; self.makeTransport = makeTransport
    }
    func start(host: String, key: String) async throws {
        var request = URLRequest(url: URL(string: "wss://" + host + "/api-ws/v1/inference")!, timeoutInterval: startupSeconds)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        queue.sync { self.request = request }
        do { try await connect() }
        catch is CancellationError { throw CancellationError() }
        catch { queue.sync { failLocked(error.localizedDescription) }; throw error }
    }
    private func connect() async throws {
        let token: UUID = try queue.sync {
            guard accepting, !closed, !finishing, let request else { throw CancellationError() }
            generation = UUID(); taskID = UUID().uuidString
            ready = false; done = false; connectionSamples = 0; pendingBytes = 0
            sentenceIDs.removeAll()
            history = history.compactMap { $0.after(confirmedThrough) }
            discardLeadingSilence()
            connectionEpoch = history.first?.time ?? through
            let token = generation, transport = makeTransport(request)
            self.transport = transport
            // A byte budget below bounds the unbounded stream. Message count is unsuitable for
            // variable SCStream buffer sizes: 300 tiny packets can be only three seconds of audio.
            let (stream, continuation) = AsyncStream<URLSessionWebSocketTask.Message>.makeStream()
            output = continuation
            sender = Task { [weak self] in
                do {
                    for await message in stream {
                        try Task.checkCancellation()
                        try await transport.send(message)
                        if case .data(let data) = message {
                            self?.queue.async { [weak self] in
                                guard let self, self.generation == token else { return }
                                self.pendingBytes = max(0, self.pendingBytes - data.count)
                            }
                        }
                    }
                } catch { self?.disconnected(token, text: "Bailian audio upload stopped.") }
            }
            receiver = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await transport.receive()
                        let data: Data
                        switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        await self?.receive(event, token: token)
                        guard let self, !self.queue.sync(execute: { self.generation != token || self.done || self.closed }) else { return }
                    }
                } catch { self?.disconnected(token, text: "Bailian transcription connection stopped.") }
            }
            enqueue(BailianMeetingProtocol.message("run-task", id: taskID))
            return token
        }
        let deadline = ProcessInfo.processInfo.systemUptime + startupSeconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let state = queue.sync { (generation == token && ready, closed || finishing || generation != token, failure) }
            if let error = state.2 { throw BailianMeetingTranscription.problem(error) }
            if state.1 { throw CancellationError() }
            if state.0 { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BailianMeetingTranscription.problem("Bailian meeting recognition did not become ready within \(Int(startupSeconds)) seconds.")
    }
    private func enqueue(_ event: [String: Any]) {
        if let bytes = try? JSONSerialization.data(withJSONObject: event) { output?.yield(.string(String(decoding: bytes, as: UTF8.self))) }
    }
    private func sendPCM(_ data: Data) {
        guard !data.isEmpty, ready, output != nil else { return }
        guard pendingBytes + data.count <= maxPendingBytes else {
            failLocked("Bailian upload has fallen more than 45 seconds behind. Transcription stopped; saved text is preserved."); return
        }
        pendingBytes += data.count; connectionSamples += data.count / 2
        output?.yield(.data(data))
    }
    private func acceptPCM(_ packet: BailianMeetingPacket) {
        history.append(packet)
        discardLeadingSilence()
        through = packet.end
        // Keep at most 60 seconds of not-yet-finalized PCM in memory for recovery. The caller
        // receives a visible warning if a longer unfinished interval cannot be replayed.
        let oldest = packet.end - 60
        if let dropped = history.last(where: { $0.end <= oldest && $0.end > confirmedThrough }) {
            discardedThrough = max(discardedThrough, dropped.end)
        }
        history.removeAll { $0.end <= max(confirmedThrough, oldest) }
        guard ready else { return }
        if connectionEpoch == nil { connectionEpoch = packet.time - Double(connectionSamples) / 16000 }
        sendPCM(packet.data)
    }
    private func discardLeadingSilence() {
        // Replaying a minute of leading silence serves no recognition purpose and would
        // consume the upload budget. Packet times still retain the skipped silent interval.
        while history.first?.isSilence == true { history.removeFirst() }
    }
    private func fillSilence(to target: Double) {
        guard var position = through, target.isFinite else { return }
        while target - position > 0.0001, failure == nil, accepting {
            let samples = min(3200, max(0, Int(((target - position) * 16000).rounded(.down))))
            if samples == 0 { break }
            acceptPCM(BailianMeetingPacket(data: Data(count: samples * 2), time: position))
            position += Double(samples) / 16000
        }
    }
    func append(_ buffer: AVAudioPCMBuffer, time: Double) {
        queue.async { [self] in
            guard accepting, !closed, !finishing, failure == nil, time.isFinite, time >= 0 else { return }
            do {
                let data = try converter.convert(buffer)
                guard !data.isEmpty else { return }
                let packet = BailianMeetingPacket(data: data, time: time)
                if through == nil {
                    through = time
                    connectionEpoch = time - Double(connectionSamples) / 16000
                    history.removeAll()
                }
                anchor = (packet.end, ProcessInfo.processInfo.systemUptime)
                guard time - through! < 120 else {
                    failLocked("Meeting audio clock jumped by more than two minutes. Transcription stopped to preserve timestamps."); return
                }
                if time > through! { fillSilence(to: time) }
                guard let remaining = packet.after(through!) else { return }
                // Split large buffers so the recovery and upload budgets remain meaningful.
                var start = remaining.time, offset = 0
                while offset < remaining.data.count, failure == nil {
                    let count = min(6400, remaining.data.count - offset)
                    acceptPCM(BailianMeetingPacket(data: Data(remaining.data[offset..<(offset + count)]), time: start))
                    offset += count; start += Double(count / 2) / 16000
                }
            } catch { failLocked("Could not convert audio for Bailian transcription.") }
        }
    }
    private func beginHeartbeat() {
        guard heartbeat == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.keepAlive() }
        heartbeat = timer; timer.resume()
    }
    private func keepAlive() {
        guard accepting, !closed, !finishing, failure == nil else { return }
        if let anchor, let through {
            // Leave half a second for capture delivery; only fill omitted SCStream silence.
            let expected = anchor.time + ProcessInfo.processInfo.systemUptime - anchor.uptime - 0.5
            if expected - through > 0.2 { fillSilence(to: expected) }
        } else if ready {
            // task-started can precede the first capture buffer, or the source may stay silent.
            // No recognition is expected here; the first actual buffer anchors the timestamps.
            sendPCM(Data(count: 8000))
        }
    }
    private func receive(_ event: [String: Any], token: UUID) async {
        let segment: TranscriptSegment? = queue.sync {
            guard !closed, generation == token, let header = event["header"] as? [String: Any], header["task_id"] as? String == taskID else { return nil }
            switch header["event"] as? String {
            case "task-started":
                guard !ready, !finishing else { return nil }
                ready = true; everReady = true
                for packet in history { sendPCM(packet.data) }
                beginHeartbeat()
                if attempt > 0 { onStatus("Bailian transcription reconnected. Continuing on the original meeting clock.") }
            case "task-finished":
                done = true
                if !finishing { disconnectLocked(token, text: "Bailian transcription ended unexpectedly.") }
            case "task-failed":
                let code = String((header["error_code"] as? String ?? "unknown").prefix(120))
                if code.lowercased().contains("timeout") || code.lowercased().contains("unavailable") {
                    disconnectLocked(token, text: "Bailian recognition interrupted: " + code)
                } else { failLocked("Bailian meeting recognition failed: " + code) }
            case "result-generated":
                guard let epoch = connectionEpoch, let payload = event["payload"] as? [String: Any],
                      let output = payload["output"] as? [String: Any], let sentence = output["sentence"] as? [String: Any], sentence["heartbeat"] as? Bool != true else { return nil }
                let key = String(describing: sentence["sentence_id"] ?? sentence["begin_time"] ?? "unknown")
                let uuid = sentenceIDs[key] ?? UUID(); sentenceIDs[key] = uuid
                let result = BailianMeetingProtocol.segment(event, source: source, epoch: epoch,
                    receivedThrough: epoch + Double(connectionSamples) / 16000, id: uuid)
                if let result, result.isFinal {
                    confirmedThrough = max(confirmedThrough, result.endTime)
                    history.removeAll { $0.end <= confirmedThrough }
                }
                return result
            default: break
            }
            return nil
        }
        if let segment { await onSegment(segment) }
    }
    private func disconnected(_ token: UUID, text: String) { queue.async { [weak self] in self?.disconnectLocked(token, text: text) } }
    private func disconnectLocked(_ token: UUID, text: String) {
        guard generation == token, !closed, failure == nil else { return }
        if finishing { failLocked(text + " The last unfinished sentence may be incomplete."); return }
        guard everReady, accepting else { failLocked(text); return }
        guard attempt < 2 else { failLocked(text + " Automatic reconnection failed twice. Saved transcript is preserved."); return }
        attempt += 1
        generation = UUID(); ready = false; done = false
        transport?.cancel(); sender?.cancel(); receiver?.cancel(); output?.finish(); output = nil
        if discardedThrough > confirmedThrough && discardedThrough.isFinite {
            onStatus("Bailian is reconnecting. An unfinished interval longer than the 60-second recovery buffer may be incomplete.")
        } else { onStatus("Bailian transcription connection interrupted. Reconnecting \(attempt)/2; audio is temporarily buffered on this Mac.") }
        reconnect = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
                try await self.connect()
            } catch is CancellationError { }
            catch {
                self.queue.async { [weak self] in
                    guard let self, !self.finishing, !self.closed else { return }
                    self.disconnectLocked(self.generation, text: "Bailian transcription could not reconnect.")
                }
            }
        }
    }
    private func failLocked(_ text: String) {
        guard failure == nil, !closed else { return }
        failure = text; accepting = false
        heartbeat?.cancel(); heartbeat = nil; reconnect?.cancel(); reconnect = nil
        onError(text)
    }
    func finish() async {
        let state = queue.sync { () -> Int in
            if closed { return 0 }
            if finishing { return 1 }
            finishing = true; accepting = false
            heartbeat?.cancel(); heartbeat = nil; reconnect?.cancel(); reconnect = nil
            if ready && failure == nil {
                enqueue(BailianMeetingProtocol.message("finish-task", id: taskID)); return 2
            }
            if !history.isEmpty && failure == nil { failLocked("Meeting ended during Bailian reconnection. The last unfinished interval may be incomplete.") }
            return 3
        }
        if state == 0 { return }
        if state == 1 {
            while !queue.sync(execute: { closed }) { try? await Task.sleep(nanoseconds: 20_000_000) }
            return
        }
        if state == 2 {
            let deadline = ProcessInfo.processInfo.systemUptime + startupSeconds
            while ProcessInfo.processInfo.systemUptime < deadline {
                if queue.sync(execute: { done || failure != nil }) { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            queue.sync { if !done && failure == nil { failLocked("Bailian finalization timed out; the last transcript interval may be incomplete.") } }
        }
        let tasks = queue.sync { () -> (Task<Void, Never>?, Task<Void, Never>?) in
            closed = true; generation = UUID(); output?.finish(); output = nil
            transport?.cancel(); transport = nil
            sender?.cancel(); receiver?.cancel()
            request = nil; history.removeAll(); sentenceIDs.removeAll(); pendingBytes = 0
            return (sender, receiver)
        }
        await tasks.0?.value; await tasks.1?.value
    }
}
