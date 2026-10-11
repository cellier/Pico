import Foundation

struct MeetingAnalysisResult: Decodable {
    var title: String?
    var summary: [MeetingDecision]?
    var suggestions: [SuggestedMeetingTask]?
    var decisions: [MeetingDecision]?
    var error: String?
}
private final class MeetingAnalysisProcess: @unchecked Sendable {
    let process = Process()
    private let lock = NSLock()
    private var cancelled = false
    func launch() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
    }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if process.isRunning { process.terminate() } }
}
enum MeetingUnderstanding {
    static func analyze(_ session: MeetingSession, dataDir: URL) async throws -> MeetingAnalysisResult {
        let encoder = JSONEncoder()
        let transcript = try JSONSerialization.jsonObject(with: encoder.encode(session.transcript))
        let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
        let input = try JSONSerialization.data(withJSONObject: ["transcript": transcript, "started": formatter.string(from: session.startTime), "ended": session.endTime.map { formatter.string(from: $0) } ?? "", "meeting_title": session.title, "provider": session.provider])
        guard let python = BundledRuntime.python(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/meeting_understanding.py") else { throw CocoaError(.fileNoSuchFile) }
        let holder = MeetingAnalysisProcess()
        let work = Task.detached(priority: .utility) {
            let process = holder.process, output = Pipe(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: python); process.arguments = ["-B", script.path]
            process.standardInput = pipe; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment.merging(["TELOS_DATA_DIR": dataDir.path]) { _, new in new }
            try holder.launch()
            try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return try JSONDecoder().decode(MeetingAnalysisResult.self, from: bytes)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { holder.cancel(); work.cancel() })
    }
    static func verified(_ evidence: TranscriptEvidence, in session: MeetingSession) -> Bool {
        session.transcript.contains { $0.id == evidence.segmentID && $0.isFinal && !$0.text.isEmpty && !evidence.text.isEmpty && $0.text.contains(evidence.text) && $0.startTime == evidence.startTime && $0.endTime == evidence.endTime }
    }
}
