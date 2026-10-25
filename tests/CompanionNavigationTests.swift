import AppKit
import Foundation

@main struct CompanionNavigationTests {
    @MainActor static func main() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("pico-companion-navigation-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = ProcessInfo.processInfo.environment
        setenv("TELOS_DATA_DIR", root.path, 1)
        // This read-only fixture loads the private store without access checks,
        // workers, calendar, audio, or a visible application/window.
        setenv("TELOS_PREVIEW", "longtext", 1)
        defer {
            try? files.removeItem(at: root)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW"] {
                if let value = original[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        var checks = 0
        func expect(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let request = UUID().uuidString
        var savedTask = Todo(title: "Private navigation fixture")
        savedTask.status = "ready"; savedTask.voiceRequestID = request
        try JSONEncoder().encode([savedTask]).write(to: root.appendingPathComponent("tasks.json"), options: .atomic)
        let store = TaskStore()
        expect(store.dataDir.standardizedFileURL == root.standardizedFileURL, "All test data must stay private")
        expect(store.tasks.first?.id == savedTask.id, "The restart fixture must be read from disk")
        let ipc = root.appendingPathComponent("companion-v1")
        try files.createDirectory(at: ipc, withIntermediateDirectories: true)
        func marker(_ id: String) throws -> URL {
            let url = ipc.appendingPathComponent(id + ".show")
            try Data().write(to: url, options: .atomic)
            return url
        }
        var shown: [UUID] = []
        let coldMarker = try marker(request)
        let bridge = CompanionBridge(store: store, transcribe: { _, _ in fatalError("Navigation must not transcribe audio") }, cancel: {}, show: { shown.append($0) })
        bridge.timer?.invalidate()
        expect(bridge.active.isEmpty, "The restart fixture must have no in-memory request map")
        expect(shown == [savedTask.id], "A persisted voice request must open after a main-app restart")
        expect(!files.fileExists(atPath: coldMarker.path), "A fulfilled open request must be consumed")

        let earlyRequest = UUID().uuidString
        let early = try marker(earlyRequest)
        bridge.poll()
        expect(files.fileExists(atPath: early.path), "An early open request must wait for its queued task")
        var earlyTask = Todo(title: "Queued private task")
        earlyTask.status = "pending"; earlyTask.voiceRequestID = earlyRequest
        store.tasks.append(earlyTask)
        bridge.poll()
        expect(shown.last == earlyTask.id && !files.fileExists(atPath: early.path), "The next poll must fulfill an early request after its task is created")

        let activeRequest = UUID().uuidString
        bridge.active[activeRequest] = savedTask.id
        let active = try marker(activeRequest)
        bridge.poll()
        expect(shown.last == savedTask.id && !files.fileExists(atPath: active.path), "Current in-memory task navigation must keep working")

        let stale = try marker(UUID().uuidString)
        try files.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: stale.path)
        let invalid = try marker("not-a-request")
        let target = root.appendingPathComponent("symlink-target")
        try Data("do not consume".utf8).write(to: target)
        let linked = ipc.appendingPathComponent(UUID().uuidString + ".show")
        try files.createSymbolicLink(at: linked, withDestinationURL: target)
        let count = shown.count
        bridge.poll()
        expect(shown.count == count, "Stale, invalid, and linked markers must not open a task")
        expect(!files.fileExists(atPath: stale.path) && !files.fileExists(atPath: invalid.path), "Expired or invalid requests must not linger")
        expect(!files.fileExists(atPath: linked.path) && files.fileExists(atPath: target.path), "Rejecting a linked marker must preserve its target")

        // The same presentation helper handles the explicit menu and approvals.
        store.showMacAccess = true; store.selected = nil
        var notifications = 0, presentations = 0
        let observer = NotificationCenter.default.addObserver(forName: .init("PicoShowTasks"), object: nil, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        CompanionTaskPresentation.show(savedTask.id, in: store) {
            expect(store.selected == savedTask.id && !store.showMacAccess, "Task selection and settings dismissal must precede window presentation")
            presentations += 1
        }
        expect(notifications == 1 && presentations == 1, "Task presentation must request the Tasks tab and show its window once")
        CompanionTaskPresentation.show(UUID(), in: store) { presentations += 1 }
        expect(notifications == 1 && presentations == 1, "A removed task must not navigate or show a misleading window")
        expect(store.tasks.count == 2 && store.tasks.first?.status == "ready", "Navigation must neither execute nor mutate stored task status")
        print("PASS: CompanionNavigation \(checks) checks; restart, queued request, validation and task presentation are isolated from live data/UI")
    }
}
