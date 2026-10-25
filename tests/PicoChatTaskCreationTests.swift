import Foundation

@main struct PicoChatTaskCreationTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicoTaskDueDates-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldDirectory = ProcessInfo.processInfo.environment["TELOS_DATA_DIR"]
        setenv("TELOS_DATA_DIR", directory.path, 1)
        defer {
            if let oldDirectory { setenv("TELOS_DATA_DIR", oldDirectory, 1) } else { unsetenv("TELOS_DATA_DIR") }
            try? FileManager.default.removeItem(at: directory)
        }
        let store = TaskStore()
        store.tasks = []
        let conversation = UUID(), request = UUID()
        func proposal(_ index: Int) -> ProposedTask { ProposedTask(title: "Follow up \(index)", instructions: "Exact context \(index)") }
        let first = try store.createChatTasks([proposal(1), proposal(2)], conversationID: conversation, request: request)
        precondition(store.tasks.count == 2 && first.count == 2)
        precondition(first.allSatisfy { $0.sourceTaskID == conversation && $0.status == "pending" })
        precondition(!store.tasks.contains { $0.id == conversation })
        let replay = try store.createChatTasks([proposal(1)], conversationID: conversation, request: request)
        precondition(replay.first?.id == first.first?.id && store.tasks.count == 2)
        _ = try store.createChatTasks([proposal(3), proposal(4), proposal(5)], conversationID: conversation, request: request)
        let persisted = try JSONDecoder().decode([Todo].self, from: Data(contentsOf: store.dataDir.appendingPathComponent("tasks.json")))
        store.tasks = persisted
        do {
            _ = try store.createChatTasks([proposal(6)], conversationID: conversation, request: request)
            fatalError("A retry must not bypass the durable five-task cap")
        } catch {}
        precondition(store.tasks.count == 5)
        _ = try store.createChatTasks([proposal(6)], conversationID: conversation, request: UUID())
        precondition(store.tasks.count == 6 && store.tasks.allSatisfy { $0.status == "pending" })
        let incoming = Data(#"[{"title":"整理 Allhands","instructions":"周四前整理","due_date":"2026-10-29"},{"title":"Review draft","instructions":"By October 30, 2026","due_date":"2026-10-30"},{"title":"排期","instructions":"下周安排，不指定某一天"}]"#.utf8)
        let dated = try JSONDecoder().decode([ProposedTask].self, from: incoming)
        precondition(dated.map(\.dueDate) == ["2026-10-29", "2026-10-30", nil])
        let dateRequest = UUID()
        let added = try store.createChatTasks(dated, conversationID: conversation, request: dateRequest)
        precondition(added.map(\.dueDate) == ["2026-10-29", "2026-10-30", nil])
        let saved = try JSONDecoder().decode([Todo].self, from: Data(contentsOf: store.dataDir.appendingPathComponent("tasks.json")))
        precondition(saved.filter { $0.creationRequest == dateRequest }.map(\.dueDate) == ["2026-10-29", "2026-10-30", nil], "Canonical optional dates must survive persistence")
        precondition(saved.filter { $0.creationRequest != dateRequest }.allSatisfy { $0.dueDate == nil }, "Existing tasks must never gain inferred dates")
        let beforeInvalid = try Data(contentsOf: store.dataDir.appendingPathComponent("tasks.json"))
        for invalid in ["2026-02-30", "2026-2-3", "2026-10-29T12:00:00", "not a date"] {
            do {
                _ = try store.createChatTasks([ProposedTask(title: "Invalid date", instructions: "Reject atomically", dueDate: invalid)], conversationID: conversation, request: UUID())
                preconditionFailure("Invalid dates must not be saved")
            } catch {}
        }
        let afterInvalid = try Data(contentsOf: store.dataDir.appendingPathComponent("tasks.json"))
        precondition(afterInvalid == beforeInvalid)
        let existingDate = added[0].dueDate
        var retry = dated[0]; retry.dueDate = "2026-11-05"
        let same = try store.createChatTasks([retry], conversationID: conversation, request: dateRequest)
        precondition(same[0].id == added[0].id && same[0].dueDate == existingDate, "A retry cannot silently reschedule an existing task")
        print("PASS: chat task quota, idempotent retry, exact optional due-date decoding/persistence, undated and existing task preservation, invalid-date atomic rejection")
    }
}
