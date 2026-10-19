import AppKit
import Foundation

@main struct StoreCheckpointRecovery {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        precondition(BundledRuntime.python() == nil, "Run as a standalone test with no worker runtime")
        unsetenv("TELOS_PREVIEW")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TelosCheckpoint-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv("TELOS_DATA_DIR", directory.path, 1)
        func task(_ title: String, status: String = "running", active: UUID? = UUID()) -> Todo {
            var todo = Todo(title: title)
            todo.status = status
            todo.activeRunID = active
            todo.messages = [Message(role: "user", text: "Local fixture request")]
            todo.approval = MacApproval(id: "fixture", actionHash: "fixture", app: "Fixture", reason: "Fixture",
                                        details: "{}", risk: "script", expiresAt: Date().addingTimeInterval(60))
            return todo
        }
        func checkpoint(_ todo: Todo, run: UUID? = nil, event: [String: Any]) throws {
            let folder = directory.appendingPathComponent("tasks/" + todo.id.uuidString.lowercased())
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["run_id": (run ?? todo.activeRunID ?? UUID()).uuidString,
                                                                  "event": event])
            try data.write(to: folder.appendingPathComponent("last-turn.json"), options: .atomic)
        }
        let matched = task("Matched done")
        let needsInput = task("Matched needs input", status: "awaiting_approval")
        let stale = task("Stale run")
        let legacy = task("Legacy task", active: nil)
        let error = task("Matched error")
        let invalidEvent = task("Invalid terminal status")
        let absent = task("No checkpoint")
        let final = task("Already completed", status: "ready")
        let todos = [matched, needsInput, stale, legacy, error, invalidEvent, absent, final]
        try checkpoint(matched, event: ["type": "done", "status": "ready", "summary": "Recovered ready", "text": "Saved final answer"])
        try checkpoint(needsInput, event: ["type": "done", "status": "needs_input", "summary": "Verify the actual state", "text": "No repeat action"])
        try checkpoint(stale, run: UUID(), event: ["type": "done", "status": "ready", "text": "Old unrelated answer"])
        try checkpoint(legacy, event: ["type": "done", "status": "ready", "text": "Unbound legacy answer"])
        try checkpoint(error, event: ["type": "error", "text": "Fixture engine error"])
        try checkpoint(invalidEvent, event: ["type": "done", "status": "running", "text": "Not a terminal event"])
        try checkpoint(final, event: ["type": "done", "status": "ready", "text": "Must not duplicate"])
        let file = directory.appendingPathComponent("tasks.json")
        try JSONEncoder().encode(todos).write(to: file, options: .atomic)
        let store = TaskStore()
        func result(_ id: UUID) -> Todo { store.tasks.first { $0.id == id }! }
        precondition(result(matched.id).status == "ready")
        precondition(result(matched.id).summary == "Recovered ready")
        precondition(result(matched.id).messages.last?.text == "Saved final answer")
        precondition(result(needsInput.id).status == "needs_input")
        precondition(result(needsInput.id).messages.last?.text == "No repeat action")
        for original in [stale, legacy, invalidEvent, absent] {
            precondition(result(original.id).status == "paused")
            precondition(result(original.id).messages.count == 1, "Unbound checkpoints must not append answers")
        }
        precondition(result(error.id).status == "error")
        precondition(result(error.id).summary == "Fixture engine error")
        precondition(result(error.id).messages.count == 1)
        precondition(result(final.id).messages.count == 1, "An already settled task is untouched")
        for original in todos where original.status != "ready" {
            precondition(result(original.id).approval == nil)
            precondition(result(original.id).activeRunID == nil)
        }
        let disk = try JSONDecoder().decode([Todo].self, from: Data(contentsOf: file))
        precondition(disk.map(\.status) == store.tasks.map(\.status), "Recovery must persist before another launch")
        let secondLaunch = TaskStore()
        precondition(secondLaunch.tasks.map(\.status) == store.tasks.map(\.status))
        precondition(secondLaunch.tasks.map { $0.messages.map(\.id) } == store.tasks.map { $0.messages.map(\.id) },
                     "Repeated launches must never append the same terminal answer twice")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        print("PASS: matched ready/needs-input/error recovery, stale/legacy/invalid/missing refusal, durable save and restart idempotence")
    }
}
