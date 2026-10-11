import Foundation
@main struct MeetingTests {
    @MainActor static func main() throws {
        let suite = "TelosMeetingPreferenceTest-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        precondition(MeetingMonitoringPreference.enabled(in: preferences))
        preferences.set(false, forKey: "TelosMeetingsEnabled")
        precondition(!MeetingMonitoringPreference.enabled(in: preferences))
        preferences.set(true, forKey: "TelosMeetingsEnabled")
        precondition(MeetingMonitoringPreference.enabled(in: preferences))
        precondition(ZoomMeetingAdapter.isJoined(controls: ["Mute", "Participants (3)", "Leave meeting"]))
        precondition(ZoomMeetingAdapter.isJoined(controls: ["静音", "参会者", "结束"]))
        precondition(!ZoomMeetingAdapter.isJoined(controls: ["Mute", "Start video", "Leave"]))
        precondition(!ZoomMeetingAdapter.isJoined(controls: ["Join", "New meeting", "Participants"]))
        precondition(ZoomMeetingAdapter.classify(controlsByWindow: [["New meeting", "Join"]], incomplete: false) == .ended)
        precondition(ZoomMeetingAdapter.classify(controlsByWindow: [["新会议", "加入"]], incomplete: false) == .ended)
        precondition(ZoomMeetingAdapter.classify(controlsByWindow: [["New meeting", "Join"], ["Mute", "Participants", "Leave meeting"]], incomplete: false) == .joined)
        precondition(ZoomMeetingAdapter.classify(controlsByWindow: [["New meeting", "Join"]], incomplete: true) == .unknown)
        precondition(ZoomMeetingAdapter.classify(controlsByWindow: [[]], incomplete: false) == .absent)
        precondition(ZoomMeetingAdapter.classify(controlsByWindow: [["New meeting", "Join"], ["Mute", "Participants"]], incomplete: false) == .unknown)
        var endGate = MeetingDebouncer()
        let start = Date()
        _ = endGate.update(.joined, at: start, remoteAudioRecently: false)
        _ = endGate.update(.joined, at: start.addingTimeInterval(5), remoteAudioRecently: false)
        _ = endGate.update(.ended, at: start.addingTimeInterval(6), remoteAudioRecently: true)
        precondition(endGate.update(.ended, at: start.addingTimeInterval(15), remoteAudioRecently: true) == false, "Zoom home ends capture even with residual Zoom audio")
        precondition(endGate.transitionTime == start.addingTimeInterval(6))
        var gate = MeetingDebouncer()
        let now = Date()
        precondition(gate.update(.joined, at: now, remoteAudioRecently: false) == nil)
        precondition(gate.update(.joined, at: now.addingTimeInterval(5), remoteAudioRecently: false) == true)
        precondition(gate.update(.absent, at: now.addingTimeInterval(6), remoteAudioRecently: false) == nil)
        precondition(gate.update(.unknown, at: now.addingTimeInterval(60), remoteAudioRecently: false) == nil)
        precondition(gate.active)
        precondition(gate.update(.absent, at: now.addingTimeInterval(100), remoteAudioRecently: true) == nil)
        precondition(gate.update(.absent, at: now.addingTimeInterval(110), remoteAudioRecently: false) == nil)
        precondition(gate.update(.absent, at: now.addingTimeInterval(141), remoteAudioRecently: false) == false)
        let store = TaskStore()
        var session = MeetingSession(title: "Weekly", status: .completed, locale: "en-US", processID: 0)
        session.endTime = Date()
        session.update(.init(startTime: 1, endTime: 2, speakerSource: .me, text: "I will", isFinal: false))
        session.update(.init(startTime: 1, endTime: 3, speakerSource: .me, text: "I will send the deck tomorrow.", isFinal: true))
        session.update(.init(startTime: 1, endTime: 2, speakerSource: .others, text: "Thank you", isFinal: true))
        precondition(session.transcript.count == 2)
        let me = session.transcript.first { $0.speakerSource == .me }!
        let ev = TranscriptEvidence(segmentID: me.id, startTime: me.startTime, endTime: me.endTime, text: me.text)
        session.summary = [MeetingDecision(text: "The revised deck will be sent tomorrow.", evidence: ev)]
        let encoded = try JSONEncoder().encode(session)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "summary")
        let oldSession = try JSONDecoder().decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(oldSession.summary == nil, "Existing meeting files must remain readable")
        for n in 1...6 { session.suggestions.append(.init(title: "Task \(n)", description: "Context \(n)", owner: "me", kind: "commitment", dueDate: nil, confidence: 0.98, evidence: ev)) }
        var parent = Todo(title: session.title, status: "completed"); parent.meetingID = session.id
        store.tasks = [parent]; store.meetings[session.id] = session
        let all = Set(session.suggestions.map(\.id))
        do { _ = try store.createMeetingTasks(meetingID: session.id, selected: all); fatalError("must limit to 5") } catch {}
        precondition(store.tasks.count == 1)
        let first = Set(session.suggestions.prefix(5).map(\.id))
        let ids = try store.createMeetingTasks(meetingID: session.id, selected: first)
        precondition(ids.count == 5 && store.tasks.count == 6)
        let replay = try store.createMeetingTasks(meetingID: session.id, selected: first)
        precondition(replay == ids && store.tasks.count == 6)
        precondition(store.tasks.filter { $0.sourceMeetingID != nil }.allSatisfy { $0.status == "pending" && $0.sourceTranscriptEvidence?.text == me.text })
        let repository = MeetingRepository(directory: store.dataDir.appendingPathComponent("meetings"))
        let restored = try repository.load().first!
        precondition(restored.summary?.first?.text == session.summary?.first?.text)
        precondition(restored.transcript.count == 2 && restored.suggestions.filter { $0.createdTaskID != nil }.count == 5)
        var bad = restored
        bad.suggestions[5].evidence.text = "invented"
        store.meetings[session.id] = bad
        do { _ = try store.createMeetingTasks(meetingID: session.id, selected: [bad.suggestions[5].id]); fatalError("evidence required") } catch {}
        precondition(store.tasks.count == 6)
        print("PASS: start/end debounce, unknown and silence handling, transcript revisions, both sources, durable evidence, max 5, idempotent confirmation")
    }
}
