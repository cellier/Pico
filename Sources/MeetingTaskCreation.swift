import Foundation

@MainActor extension TaskStore {
    @discardableResult func createMeetingTasks(meetingID: UUID, selected: Set<UUID>) throws -> [UUID] {
        func failure(_ text: String) -> NSError { NSError(domain: "MeetingTasks", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard (1...5).contains(selected.count), var session = meetings[meetingID], [.completed, .interrupted].contains(session.status),
              let parent = tasks.first(where: { $0.meetingID == meetingID }) else { throw failure("Select 1–5 suggestions from a finished meeting.") }
        let candidates = session.suggestions.filter { selected.contains($0.id) }
        guard candidates.count == selected.count, candidates.allSatisfy({ MeetingUnderstanding.verified($0.evidence, in: session) && $0.confidence >= 0.85 && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw failure("Selected suggestions need verified transcript evidence.") }
        var updated = tasks, ids: [UUID] = []
        for candidate in candidates {
            if let existing = updated.first(where: { $0.sourceMeetingID == meetingID && $0.sourceSuggestionID == candidate.id }) { ids.append(existing.id); continue }
            let evidence = "\n\nMeeting: \(session.title)\nEvidence (\(meetingTimestamp(candidate.evidence.startTime))): \(candidate.evidence.text)"
            var todo = Todo(title: candidate.title, summary: "Not started", status: "pending", messages: [.init(role: "user", text: candidate.description + evidence)])
            todo.sourceTaskID = parent.id; todo.sourceMeetingID = meetingID; todo.sourceSuggestionID = candidate.id
            todo.sourceTranscriptEvidence = candidate.evidence; todo.dueDate = candidate.dueDate
            updated.insert(todo, at: 0); ids.append(todo.id)
        }
        // tasks.json is the authoritative creation receipt. Recover links from it after a crash.
        let url = dataDir.appendingPathComponent("tasks.json")
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        tasks = updated
        for i in session.suggestions.indices {
            session.suggestions[i].createdTaskID = tasks.first(where: { $0.sourceMeetingID == meetingID && $0.sourceSuggestionID == session.suggestions[i].id })?.id
        }
        meetings[meetingID] = session
        // A failure here must never be reported as task-creation failure (tasks already committed).
        do { try MeetingRepository(directory: dataDir.appendingPathComponent("meetings")).save(session) }
        catch { self.error = "Tasks were created, but meeting links could not be saved. They will be recovered when Telos next opens." }
        return ids
    }
}
