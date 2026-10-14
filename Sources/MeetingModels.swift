import Foundation

enum SpeakerSource: String, Codable { case me, others }
enum MeetingStatus: String, Codable { case preparing, recording, finishing, completed, interrupted }
struct TranscriptSegment: Codable, Identifiable {
    var id = UUID()
    var startTime: Double
    var endTime: Double
    var speakerSource: SpeakerSource
    var text: String
    var isFinal: Bool
    var excludedFromEvidence: Bool? = nil // Retain uncertain switch-boundary audio, but never treat it as an owner statement.
}
struct MeetingAgentAudioInterval {
    var start: Double
    var end: Double? = nil
}
enum MeetingAudioAttribution {
    static func classified(_ segment: TranscriptSegment, agentIntervals: [MeetingAgentAudioInterval]) -> TranscriptSegment {
        var result = segment
        if segment.speakerSource == .me && agentIntervals.contains(where: {
            segment.startTime < ($0.end ?? .greatestFiniteMagnitude) && segment.endTime > $0.start
        }) { result.excludedFromEvidence = true }
        return result
    }
}
struct TranscriptEvidence: Codable {
    var segmentID: UUID
    var startTime: Double
    var endTime: Double
    var text: String
}
struct SuggestedMeetingTask: Codable, Identifiable {
    var id = UUID()
    var title: String
    var description: String
    var owner: String
    var kind: String
    var dueDate: String?
    var confidence: Double
    var evidence: TranscriptEvidence
    var createdTaskID: UUID?
}
struct MeetingDecision: Codable, Identifiable {
    var id = UUID()
    var text: String
    var evidence: TranscriptEvidence
}
struct MeetingSession: Codable, Identifiable {
    var id = UUID()
    var provider = "Zoom"
    var transcriptionEngine: String?
    var title: String
    var startTime = Date()
    var endTime: Date?
    var transcript: [TranscriptSegment] = []
    var status: MeetingStatus = .preparing
    var suggestions: [SuggestedMeetingTask] = []
    var decisions: [MeetingDecision] = []
    var summary: [MeetingDecision]?
    var analysisStatus = "not_started"
    var notice: String?
    var locale: String
    var processID: Int32
    var picoRecords: [PicoMeetingRecord]? // Agent output/events are not participant evidence.
    mutating func update(_ segment: TranscriptSegment) {
        transcript.removeAll { $0.id == segment.id }
        // Volatile text may change its end boundary; replace by overlapping source range.
        transcript.removeAll { !$0.isFinal && $0.speakerSource == segment.speakerSource && $0.startTime < segment.endTime + 0.01 && $0.endTime > segment.startTime - 0.01 }
        guard !transcript.contains(where: { $0.isFinal && $0.speakerSource == segment.speakerSource && abs($0.startTime - segment.startTime) < 0.01 && $0.text == segment.text }) else { return }
        transcript.append(segment)
        transcript.sort { $0.startTime < $1.startTime }
    }
}
struct MeetingRepository {
    let directory: URL
    func save(_ session: MeetingSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(session.id.uuidString + ".json")
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func load(onError: (String) -> Void = { _ in }) throws -> [MeetingSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var sessions: [MeetingSession] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "json" }) {
            do { sessions.append(try JSONDecoder().decode(MeetingSession.self, from: Data(contentsOf: url))) }
            catch { onError("Could not load meeting " + url.deletingPathExtension().lastPathComponent + ". Its saved file has been kept.") }
        }
        return sessions
    }
}

/// Preserve an explicit opt-out; a missing setting must not silently disable the feature.
enum MeetingMonitoringPreference {
    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "TelosMeetingsEnabled") == nil || defaults.bool(forKey: "TelosMeetingsEnabled")
    }
}
