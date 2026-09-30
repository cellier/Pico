import Foundation
@main struct TaskCreationTests {
    @MainActor static func main() throws {
        let store = TaskStore()
        let source = Todo(title: "Parent")
        store.tasks = [source]
        let request = UUID()
        func proposal(_ n: Int) -> ProposedTask { ProposedTask(title: "Task \(n)", instructions: "Context \(n)") }
        let first = try store.createTasks([proposal(1), proposal(2), proposal(3)], source: source.id, request: request)
        precondition(first.count == 3 && first.allSatisfy { $0.status == "pending" })
        let replay = try store.createTasks([proposal(1)], source: source.id, request: request)
        precondition(replay.first?.id == first.first?.id && store.tasks.count == 4)
        do { _ = try store.createTasks([proposal(4), proposal(5), proposal(6)], source: source.id, request: request); fatalError("quota") } catch {}
        precondition(store.tasks.count == 4)
        _ = try store.createTasks([proposal(4), proposal(5)], source: source.id, request: request)
        precondition(store.tasks.count == 6)
        let persisted = try JSONDecoder().decode([Todo].self, from: Data(contentsOf: store.dataDir.appendingPathComponent("tasks.json")))
        store.tasks = persisted
        do { _ = try store.createTasks([proposal(6)], source: source.id, request: request); fatalError("durable quota") } catch {}
        _ = try store.createTasks([proposal(6)], source: source.id, request: UUID())
        precondition(store.tasks.count == 7)
        do { _ = try store.createTasks([ProposedTask(title: "", instructions: "x")], source: source.id, request: UUID()); fatalError("validation") } catch {}
        let before = store.tasks.count
        try FileManager.default.removeItem(at: store.dataDir.appendingPathComponent("tasks.json"))
        try FileManager.default.createDirectory(at: store.dataDir.appendingPathComponent("tasks.json"), withIntermediateDirectories: false)
        do { _ = try store.createTasks([proposal(8)], source: source.id, request: UUID()); fatalError("disk failure") } catch {}
        precondition(store.tasks.count == before)
        print("PASS: atomic quota, replay, persisted retry, new request, pending tasks, validation and disk failure")
    }
}
