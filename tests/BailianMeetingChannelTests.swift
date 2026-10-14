import Foundation
import AVFoundation

// The focused runner compiles the real channel with small account/model stubs. Full app
// builds use their real definitions. Neither mode opens a keychain or a network socket.
#if BAILIAN_CHANNEL_STANDALONE
enum SpeakerSource: String { case me, others }
struct TranscriptSegment {
    var id: UUID; var startTime: Double; var endTime: Double
    var speakerSource: SpeakerSource; var text: String; var isFinal: Bool
}
protocol MeetingTranscribing: AnyObject {
    var onSegment: ((TranscriptSegment) async -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func start(localeID: String) async throws
    func append(_ buffer: AVAudioPCMBuffer, source: SpeakerSource, time: Double)
    func finish() async
}
struct DictationBailianAccount {
    var endpoint: URL? { URL(string: "https://unused.invalid") }
    var account = "test"
    static var saved: Self { Self() }
    static func key(_ account: String) -> String? { nil }
}
#endif

private final class ChannelObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TranscriptSegment] = [], messages: [String] = [], problems: [String] = []
    func segment(_ value: TranscriptSegment) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func status(_ text: String) { lock.lock(); defer { lock.unlock() }; messages.append(text) }
    func error(_ text: String) { lock.lock(); defer { lock.unlock() }; problems.append(text) }
    func snapshot() -> ([TranscriptSegment], [String], [String]) { lock.lock(); defer { lock.unlock() }; return (values, messages, problems) }
}
private final class SimulatedMeetingSocket: BailianMeetingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var awaiting: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var inbox: [Result<URLSessionWebSocketTask.Message, Error>] = []
    private var id = "", bytes = 0, canceled = false, finishes = 0
    let ready: Bool
    let slowAudio: Bool
    init(ready: Bool = true, slowAudio: Bool = false) { self.ready = ready; self.slowAudio = slowAudio }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        switch message {
        case .data(let data):
            if slowAudio { try await Task.sleep(nanoseconds: 1_000_000_000) }
            addBytes(data.count)
        case .string(let text):
            guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let header = object["header"] as? [String: Any] else { return }
            if header["action"] as? String == "run-task" {
                setID(header["task_id"] as! String)
                if ready { pushEvent("task-started") }
            } else if header["action"] as? String == "finish-task" { countFinish(); pushEvent("task-finished") }
        @unknown default: break
        }
    }
    private func addBytes(_ count: Int) { lock.lock(); defer { lock.unlock() }; bytes += count }
    private func setID(_ id: String) { lock.lock(); defer { lock.unlock() }; self.id = id }
    private func countFinish() { lock.lock(); defer { lock.unlock() }; finishes += 1 }
    func snapshot() -> (String, Int, Int, Bool) { lock.lock(); defer { lock.unlock() }; return (id, bytes, finishes, canceled) }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty { let next = inbox.removeFirst(); lock.unlock(); continuation.resume(with: next) }
            else if canceled { lock.unlock(); continuation.resume(throwing: URLError(.cancelled)) }
            else { precondition(awaiting == nil); awaiting = continuation; lock.unlock() }
        }
    }
    private func push(_ value: Result<URLSessionWebSocketTask.Message, Error>) {
        lock.lock()
        if let next = awaiting { awaiting = nil; lock.unlock(); next.resume(with: value) }
        else { inbox.append(value); lock.unlock() }
    }
    func pushEvent(_ name: String, sentence: [String: Any]? = nil) {
        var event: [String: Any] = ["header": ["event": name, "task_id": snapshot().0]]
        if let sentence { event["payload"] = ["output": ["sentence": sentence]] }
        let data = try! JSONSerialization.data(withJSONObject: event)
        push(.success(.string(String(decoding: data, as: UTF8.self))))
    }
    func interrupt() { push(.failure(URLError(.networkConnectionLost))) }
    func cancel() {
        lock.lock(); canceled = true; let waiting = awaiting; awaiting = nil; lock.unlock()
        waiting?.resume(throwing: URLError(.cancelled))
    }
}
private final class SimulatedSockets: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [SimulatedMeetingSocket] = []
    let ready: Bool, slowAudio: Bool
    init(ready: Bool = true, slowAudio: Bool = false) { self.ready = ready; self.slowAudio = slowAudio }
    func make(_ request: URLRequest) -> any BailianMeetingTransport {
        precondition(request.url?.host == "unused.invalid")
        let socket = SimulatedMeetingSocket(ready: ready, slowAudio: slowAudio)
        lock.lock(); sockets.append(socket); lock.unlock(); return socket
    }
    func all() -> [SimulatedMeetingSocket] { lock.lock(); defer { lock.unlock() }; return sockets }
}
@main struct BailianMeetingChannelTests {
    static func wait(_ condition: () -> Bool, seconds: Double = 3) async throws {
        let until = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < until, "Timed out waiting for simulated lifecycle")
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func buffer(_ seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let frames = AVAudioFrameCount(seconds * 16000)
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        result.frameLength = frames
        for i in 0..<Int(frames) { result.int16ChannelData![0][i] = Int16(i % 500) }
        return result
    }
    private static func channel(_ sockets: SimulatedSockets, _ output: ChannelObservation, timeout: Double = 1) -> BailianMeetingChannel {
        BailianMeetingChannel(source: .others, onSegment: { output.segment($0) }, onError: { output.error($0) },
            onStatus: { output.status($0) }, startupSeconds: timeout, retryDelay: 0.02, makeTransport: sockets.make)
    }
    static func main() async throws {
        let run = BailianMeetingProtocol.message("run-task", id: UUID().uuidString)
        let payload = run["payload"] as! [String: Any], parameters = payload["parameters"] as! [String: Any]
        precondition(payload["model"] as? String == "qwen-audio-3.1-asr-flash-streaming")
        precondition(parameters["heartbeat"] as? Bool == true && parameters["semantic_punctuation_enabled"] as? Bool == true)
        precondition(parameters["vad_model"] as? String == "near_meeting_16k")
        let packet = BailianMeetingPacket(data: Data(count: 3200), time: 1)
        precondition(packet.after(-Double.infinity)?.data.count == 3200)
        precondition(packet.after(1.05)?.data.count == 1600)
        precondition(packet.after(1.1) == nil)

        let sockets = SimulatedSockets(), output = ChannelObservation(), stream = channel(sockets, output)
        try await stream.start(host: "unused.invalid", key: "simulated-not-a-secret")
        let first = sockets.all()[0]
        stream.append(buffer(0.1), time: 10)
        try await wait { first.snapshot().1 >= 3200 }
        first.pushEvent("result-generated", sentence: ["sentence_id": 1, "begin_time": 0, "end_time": 100, "text": "开始", "sentence_end": true])
        try await wait { output.snapshot().0.count == 1 }
        precondition(abs(output.snapshot().0[0].startTime - 10) < 0.001)
        stream.append(buffer(0.1), time: 12)
        try await wait { first.snapshot().1 >= 64000 }
        first.interrupt()
        try await wait { sockets.all().count == 2 && sockets.all()[1].snapshot().1 >= 3200 }
        let second = sockets.all()[1]
        second.pushEvent("result-generated", sentence: ["sentence_id": 1, "begin_time": 0, "end_time": 100, "text": "继续", "sentence_end": true])
        try await wait { output.snapshot().0.count == 2 }
        let segments = output.snapshot().0
        precondition(abs(segments[1].startTime - 12) < 0.001 && segments[0].id != segments[1].id)
        precondition(output.snapshot().1.contains(where: { $0.contains("reconnected") }) && output.snapshot().2.isEmpty)
        // SCStream may provide no buffers during silence. A gap beyond the old 30-second
        // failure threshold must retain its clock and continue, and heartbeat adds real PCM.
        stream.append(buffer(0.1), time: 50)
        try await wait { second.snapshot().1 >= 38 * 32000 }
        let beforeSilence = second.snapshot().1
        try await wait({ second.snapshot().1 > beforeSilence }, seconds: 2)
        precondition(output.snapshot().2.isEmpty)
        // Leading silence is omitted from replay while its original clock is retained.
        second.interrupt()
        try await wait { sockets.all().count == 3 && sockets.all()[2].snapshot().1 >= 3200 }
        let last = sockets.all()[2]
        precondition(last.snapshot().1 < 32000)
        last.pushEvent("result-generated", sentence: ["sentence_id": 1, "begin_time": 0, "end_time": 100, "text": "静音后继续", "sentence_end": true])
        try await wait { output.snapshot().0.count == 3 }
        precondition(abs(output.snapshot().0[2].startTime - 50) < 0.001)
        // finish-task has to drain captured PCM and accept final events exactly once.
        async let finishA: Void = stream.finish()
        async let finishB: Void = stream.finish()
        _ = await (finishA, finishB)
        precondition(last.snapshot().2 == 1 && last.snapshot().3)
        let afterFinish = last.snapshot().1
        last.pushEvent("result-generated", sentence: ["sentence_id": 9, "begin_time": 0, "end_time": 100, "text": "late", "sentence_end": true])
        stream.append(buffer(0.1), time: 90)
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(last.snapshot().1 == afterFinish && output.snapshot().0.count == 3)

        let failures = SimulatedSockets(), failureLog = ChannelObservation(), failing = channel(failures, failureLog)
        try await failing.start(host: "unused.invalid", key: "simulated-not-a-secret")
        for count in 1...3 {
            try await wait { failures.all().count == count && !failures.all()[count - 1].snapshot().0.isEmpty }
            failures.all()[count - 1].interrupt()
        }
        try await wait { failureLog.snapshot().2.count == 1 }
        precondition(failures.all().count == 3 && failureLog.snapshot().2[0].contains("failed twice"))
        await failing.finish()

        let handshake = SimulatedSockets(ready: false), handshakeLog = ChannelObservation(), unready = channel(handshake, handshakeLog, timeout: 0.12)
        do { try await unready.start(host: "unused.invalid", key: "simulated-not-a-secret"); preconditionFailure("Expected startup timeout") } catch { }
        await unready.finish()
        precondition(handshake.all().count == 1 && handshakeLog.snapshot().2.count == 1)

        let slow = SimulatedSockets(slowAudio: true), slowLog = ChannelObservation(), congested = channel(slow, slowLog)
        try await congested.start(host: "unused.invalid", key: "simulated-not-a-secret")
        congested.append(buffer(46), time: 1)
        try await wait { slowLog.snapshot().2.count == 1 }
        precondition(slowLog.snapshot().2[0].contains("45 seconds behind"))
        await congested.finish()
        print("PASS: real channel with simulated transport: Qwen 3.1 protocol, silence heartbeat and >30s gap, replay with original timestamps and unique IDs, two bounded reconnects, startup timeout, bounded backlog, idempotent finalization and late callback suppression. No network or credentials used.")
    }
}
