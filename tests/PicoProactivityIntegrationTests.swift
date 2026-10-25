import AppKit
import Foundation

@main struct PicoProactivityIntegrationTests {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicoProactiveIntegration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldDirectory = ProcessInfo.processInfo.environment["TELOS_DATA_DIR"]
        setenv("TELOS_DATA_DIR", root.path, 1)
        let suite = "PicoProactiveTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            if let oldDirectory { setenv("TELOS_DATA_DIR", oldDirectory, 1) } else { unsetenv("TELOS_DATA_DIR") }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        var clock = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10))!
        let initial = (0..<260).map { Message(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Fixture message \($0)", date: clock) }
        let messages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(initial))
        let snapshot: [String: Any] = ["conversationID": UUID().uuidString, "messages": messages, "artifacts": [], "status": "idle"]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: root.appendingPathComponent("chat.json"))
        let tasks = TaskStore()
        let chat = PicoChatStore(dataDir: root, taskStore: tasks)
        chat.showMessage(containing: initial[0].id)
        chat.setFollowsLatest(false)
        let reading = chat.messages.map(\.id)
        let notice = UUID()
        precondition(chat.appendProactiveNotice(id: notice, text: "Synthetic important update", date: clock))
        precondition(chat.messages.map(\.id) == reading && chat.hasLaterMessages,
                     "An unsolicited update must not replace the history page or jump to latest")
        precondition(chat.status == "idle" && !chat.isRunning && chat.stream.isEmpty)
        precondition(chat.recentProactiveContext.last?["id"] == notice.uuidString)
        precondition(chat.appendProactiveNotice(id: notice, text: "Duplicate must be ignored", date: clock))
        let reloaded = PicoChatStore(dataDir: root)
        precondition(reloaded.searchMessages("Synthetic important update").count == 1)
        precondition(reloaded.messages.last?.origin == "proactive" && reloaded.messages.last?.role == "assistant")
        let before = try Data(contentsOf: root.appendingPathComponent("chat.json"))
        chat.draft = "Unsent text"
        precondition(!chat.appendProactiveNotice(id: UUID(), text: "Wait for the draft", date: clock))
        precondition(chat.draft == "Unsent text")
        chat.draft = ""
        chat.files = [ComposerFile(name: "Unsent attachment", path: root.appendingPathComponent("not-opened.txt").path)]
        precondition(!chat.appendProactiveNotice(id: UUID(), text: "Wait for the attachment", date: clock))
        chat.files = []
        chat.diagnosticsStream("Partial response", running: true)
        let owner = chat.responseMessageID
        precondition(!chat.appendProactiveNotice(id: UUID(), text: "Wait for the running reply", date: clock))
        precondition(chat.stream == "Partial response" && chat.responseMessageID == owner && chat.isRunning)
        chat.diagnosticsStream("", running: false)
        let afterBlockedNotices = try Data(contentsOf: root.appendingPathComponent("chat.json"))
        precondition(afterBlockedNotices == before)

        let calendar = CalendarStore(directory: root, automaticallyRefresh: false, previewMode: nil)
        let coordinator = PicoProactiveCoordinator(directory: root, taskStore: tasks, calendar: calendar,
                                                   defaults: defaults, clock: { clock })
        coordinator.organizeContext = false
        coordinator.attach(chat: chat)
        let stateFile = root.appendingPathComponent("proactive-state.json")
        let firstStateAttributes = try FileManager.default.attributesOfItem(atPath: stateFile.path)
        coordinator.evaluate(); coordinator.evaluate()
        let repeatedStateAttributes = try FileManager.default.attributesOfItem(atPath: stateFile.path)
        precondition((firstStateAttributes[.systemFileNumber] as? NSNumber) == (repeatedStateAttributes[.systemFileNumber] as? NSNumber),
                     "An unchanged reminder tick must not atomically replace the state file")
        try FileManager.default.removeItem(at: stateFile)
        coordinator.evaluate()
        precondition(FileManager.default.fileExists(atPath: stateFile.path), "A missing state file must be restored even if cached bytes match")
        try FileManager.default.removeItem(at: stateFile)
        try FileManager.default.createDirectory(at: stateFile, withIntermediateDirectories: false)
        coordinator.evaluate()
        precondition(coordinator.settingsMessage != nil, "A storage failure must not be hidden by the unchanged-state cache")
        try FileManager.default.removeItem(at: stateFile)
        coordinator.evaluate()
        _ = try JSONDecoder().decode(PicoProactiveRules.self, from: Data(contentsOf: stateFile))
        var task = Todo(title: "Synthetic background task")
        task.status = "running"; tasks.tasks = [task]; coordinator.evaluate()
        task.status = "needs_input"; task.messages = [Message(role: "assistant", text: "Synthetic question")]
        tasks.tasks = [task]
        chat.draft = "Keep typing"
        coordinator.evaluate()
        precondition(chat.searchMessages("需要你的补充").isEmpty)
        chat.draft = ""; coordinator.evaluate()
        precondition(chat.searchMessages("需要你的补充").count == 1)
        let recovered = PicoProactiveCoordinator(directory: root, taskStore: tasks, calendar: calendar,
                                                 defaults: defaults, clock: { clock })
        recovered.attach(chat: chat); recovered.evaluate()
        precondition(chat.searchMessages("需要你的补充").count == 1, "Reloaded reminder state must not replay a notice")
        coordinator.activityIsBusy = { true }
        task.status = "running"; tasks.tasks = [task]; coordinator.evaluate()
        task.status = "error"; task.messages.append(Message(role: "assistant", text: "Synthetic failure")); tasks.tasks = [task]
        clock = clock.addingTimeInterval(11 * 60); coordinator.evaluate()
        precondition(chat.searchMessages("遇到了问题").isEmpty)
        coordinator.activityIsBusy = { false }; coordinator.evaluate()
        precondition(chat.searchMessages("遇到了问题").count == 1)
        coordinator.stop(); recovered.stop()

        let failureRoot = root.appendingPathComponent("failure")
        let failing = PicoChatStore(dataDir: failureRoot)
        precondition(failing.appendProactiveNotice(id: UUID(), text: "Saved notice", date: clock))
        let ids = failing.messages.map(\.id)
        try FileManager.default.removeItem(at: failureRoot.appendingPathComponent("chat.json"))
        try FileManager.default.createDirectory(at: failureRoot.appendingPathComponent("chat.json"), withIntermediateDirectories: false)
        precondition(!failing.appendProactiveNotice(id: UUID(), text: "Unsaved notice", date: clock))
        precondition(failing.messages.map(\.id) == ids && failing.error == nil,
                     "Failed background persistence must roll back the message without disrupting Chat")
        print("PASS: real Chat history preservation, stable notice recovery/dedup, draft/attachment/stream safety, idle-state preservation, coordinator queue delivery, recording delay and failed-save rollback")
        try PicoChatStoreTests.main()
        try PicoProactivityTests.main()
        try await ZoomCalendarStoreTests.main()
    }
}
