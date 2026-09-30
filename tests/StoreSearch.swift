import Foundation
@main struct StoreSearch {
    @MainActor static func main() throws {
        let store = TaskStore()
        var first = Todo(title: "Build a portfolio")
        first.status = "ready"; first.messages = [Message(role: "user", text: "使用蓝色和简洁布局")]
        first.artifacts = [Artifact(path: "/tmp/index.html", name: "index.html")]
        var second = Todo(title: "Meeting summary"); second.status = "completed"
        store.tasks = [first, second]
        precondition(store.searchTasks("PORTFOLIO").count == 1)
        precondition(store.searchTasks("蓝色").first?.id == first.id)
        precondition(store.searchTasks("index.html").first?.id == first.id)
        precondition(store.searchTasks("Meeting").first?.id == second.id)
        precondition(store.searchTasks("portfolio index").count == 1)
        precondition(store.searchTasks("missing").isEmpty)
        // Older task files have no feedID: decoding must remain backward compatible.
        let encoded = try JSONEncoder().encode([first, second])
        let restored = try JSONDecoder().decode([Todo].self, from: encoded)
        precondition(restored.count == 2 && restored[0].feedID == nil)
        print("Task title/message/artifact search, completed-task search and old-file compatibility: PASS")
    }
}
