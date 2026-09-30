import Foundation
@main struct StoreCompletion {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TELOS_DATA_DIR"]!)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = TaskStore()
        for status in ["ready", "needs_input", "error", "paused", "running", "awaiting_approval"] {
            var todo = Todo(title: status); todo.status = status
            todo.approval = MacApproval(id: "stale", actionHash: "hash", app: "Test", reason: "Test", details: "{}", risk: "action", expiresAt: .distantFuture)
            store.tasks = [todo]; store.selected = todo.id
            store.complete(todo.id)
            precondition(store.tasks[0].status == "completed")
            precondition(store.tasks[0].approval == nil && store.selected == nil)
            store.decide(todo.id, approve: true)
            precondition(store.tasks[0].status == "completed")
            let restored = TaskStore()
            precondition(restored.tasks[0].status == "completed")
            precondition(restored.tasks[0].completedAt != nil)
            store.reopen(todo.id)
            precondition(store.tasks[0].status == "ready")
            precondition(store.tasks[0].completedAt == nil)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
        var samples: [Todo] = []
        for days in [0, 1, 2, 7, 30] {
            var task = Todo(title: "Day \(days)"); task.status = "completed"
            task.completedAt = calendar.date(byAdding: .day, value: -days, to: now)
            samples.append(task)
        }
        var legacy = Todo(title: "Legacy"); legacy.status = "completed"; samples.append(legacy)
        let groups = CompletionSection.group(samples, now: now, calendar: calendar)
        precondition(groups.map(\.title) == ["Today", "Yesterday", "This Week", "Last Week", "Earlier", "Completed Earlier"])
        let monday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 12))!
        samples[0].completedAt = calendar.date(byAdding: .day, value: -1, to: monday)
        precondition(CompletionSection.group([samples[0]], now: monday, calendar: calendar).first?.title == "Yesterday")
        print("Complete all task states, clear approvals, persist, and reopen: PASS")
    }
}
