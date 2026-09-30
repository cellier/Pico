import Foundation

struct ProposedTask: Codable {
    var title: String
    var instructions: String
}

@MainActor extension TaskStore {
    /// A user's message ID is the durable quota key, including retries after restart.
    func createTasks(_ proposals: [ProposedTask], source: UUID, request: UUID) throws -> [Todo] {
        func invalid(_ text: String) -> NSError { NSError(domain: "Telos.TaskCreation", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
        guard tasks.contains(where: { $0.id == source }), (1...5).contains(proposals.count) else {
            throw invalid("Create between 1 and 5 tasks from an existing conversation.")
        }
        var result: [Todo] = []
        var additions: [Todo] = []
        let existing = tasks.filter { $0.creationRequest == request }
        for proposal in proposals {
            let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = proposal.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 160, !text.isEmpty, text.count <= 20000 else {
                throw invalid("Each task needs a short title and complete instructions.")
            }
            if let same = (existing + additions).first(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame && $0.messages.first?.text == text }) {
                result.append(same); continue
            }
            guard existing.count + additions.count < 5 else { throw invalid("This user request already reaches the 5-task limit. No additional tasks were created.") }
            var todo = Todo(title: title, summary: "Not started", status: "pending", messages: [Message(role: "user", text: text)])
            todo.creationRequest = request; todo.sourceTaskID = source
            additions.append(todo); result.append(todo)
        }
        let updated = additions + tasks
        // Persist before publishing or acknowledging; failure leaves the list untouched.
        let file = dataDir.appendingPathComponent("tasks.json")
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        tasks = updated
        return result
    }
}
