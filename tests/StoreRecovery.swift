import Foundation
@main struct StoreRecovery {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TELOS_DATA_DIR"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var waiting = Todo(title: "Pending confirmation")
        waiting.status = "awaiting_approval"
        waiting.approval = MacApproval(id: "old", actionHash: "oldhash", app: "Fixture", reason: "Old action", details: "{}", risk: "action", expiresAt: Date().addingTimeInterval(300))
        var finished = Todo(title: "Existing completed task"); finished.status = "completed"
        try JSONEncoder().encode([waiting, finished]).write(to: root.appendingPathComponent("tasks.json"))
        let store = TaskStore()
        precondition(store.tasks[0].status == "paused")
        precondition(store.tasks[0].approval == nil)
        precondition(store.tasks[1].status == "completed")
        store.decide(waiting.id, approve: true)
        precondition(store.tasks[0].status == "paused")
        print("Restart invalidates approval; completed tasks preserved; stale decisions cannot execute: PASS")
    }
}
