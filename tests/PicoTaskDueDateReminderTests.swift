import AppKit
import Foundation

/// Real event decoding, Todo persistence, coordinator delivery and Chat recovery;
/// all data and preferences are isolated, with no agent or external service.
@main struct PicoTaskDueDateReminderTests {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicoDueReminder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldDirectory = ProcessInfo.processInfo.environment["TELOS_DATA_DIR"]
        setenv("TELOS_DATA_DIR", root.path, 1)
        let suite = "PicoDueReminder-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            if let oldDirectory { setenv("TELOS_DATA_DIR", oldDirectory, 1) }
            else { unsetenv("TELOS_DATA_DIR") }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = TaskStore()
        let event = try JSONDecoder().decode(WorkerEvent.self, from: Data(#"{"type":"create_tasks","tasks":[{"title":"整理 Allhands","instructions":"周四前整理 Allhands","due_date":"2026-10-29"},{"title":"安排排期","instructions":"下周安排，没有指定截止日"}]}"#.utf8))
        let created = try store.createChatTasks(event.tasks!, conversationID: UUID(), request: UUID())
        precondition(created.map(\.dueDate) == ["2026-10-29", nil])
        let taskBytes = try Data(contentsOf: root.appendingPathComponent("tasks.json"))
        let saved = try JSONDecoder().decode([Todo].self, from: taskBytes)
        precondition(saved.map(\.dueDate) == ["2026-10-29", nil])
        store.tasks = saved
        let calendar = CalendarStore(directory: root, automaticallyRefresh: false, previewMode: nil)
        var now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 21))!
        let chat = PicoChatStore(dataDir: root, taskStore: store)
        let coordinator = PicoProactiveCoordinator(directory: root, taskStore: store, calendar: calendar,
                                                   defaults: defaults, clock: { now })
        coordinator.organizeContext = false
        coordinator.attach(chat: chat)
        precondition(chat.messages.isEmpty, "A future deadline must not notify early")
        now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 8, minute: 5))!
        coordinator.evaluate()
        let notices = chat.messages.filter { $0.origin == "proactive" }
        precondition(notices.count == 1 && notices[0].text.contains("整理 Allhands") && notices[0].text.contains("今天到期"))
        coordinator.evaluate()
        precondition(chat.messages.filter { $0.origin == "proactive" }.count == 1)
        let reloadedChat = PicoChatStore(dataDir: root, taskStore: store)
        let recovered = PicoProactiveCoordinator(directory: root, taskStore: store, calendar: calendar,
                                                 defaults: defaults, clock: { now })
        recovered.organizeContext = false
        recovered.attach(chat: reloadedChat); recovered.evaluate()
        precondition(reloadedChat.messages.filter { $0.origin == "proactive" }.map(\.id) == notices.map(\.id),
                     "The actual persisted proactive message must survive reopening without duplication")
        let unchangedTasks = try Data(contentsOf: root.appendingPathComponent("tasks.json"))
        precondition(unchangedTasks == taskBytes, "Reminder delivery never starts or rewrites tasks")
        coordinator.stop(); recovered.stop()
        print("PASS: create_tasks event → real persisted Todo.dueDate → next-day coordinator → one durable proactive Chat message; no undated reminders, duplicate messages or task execution")
    }
}
