import Combine
import Foundation

@main struct PicoTaskListIndexTests {
    @MainActor static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        let now = Date(timeIntervalSince1970: 1_792_670_400) // deterministic daytime; no real clock dependency
        let today = calendar.startOfDay(for: now)
        let model = PicoTaskListIndex()
        var tasks = (0..<10_000).map { index -> Todo in
            var task = Todo(title: "Task \(index)")
            task.status = "ready"; task.summary = "Ready \(index)"
            return task
        }
        tasks[9999].messages = [Message(role: "assistant", text: "Historical transcript only needle 中文")]
        tasks[9998].artifacts = [Artifact(path: "archive/report.pdf", name: "needle-report.pdf")]
        func page(_ query: String = "", done: Bool = false, revision: Int = 0, follow: Bool = false,
                  time: Date? = nil) -> [PicoTaskListRow] {
            model.rows(tasks: tasks, revision: revision, completed: done, query: query,
                       now: time ?? now, calendar: calendar, followsTop: follow)
        }
        func ids(_ rows: [PicoTaskListRow]) -> [UUID] { rows.compactMap { $0.task?.id } }
        let allIDs = tasks.map(\.id)
        var rows = page(follow: true)
        precondition(ids(rows) == Array(allIDs.prefix(80)))
        precondition(model.totalMatchCount == 10_000 && !model.hasEarlier && model.hasLater)
        for _ in 0..<30 {
            let previous = Set(ids(rows)); model.loadLater(); rows = page()
            precondition(model.visibleTaskCount <= 240 && !previous.intersection(ids(rows)).isEmpty)
        }
        precondition(model.hasEarlier && model.hasLater)
        let reading = ids(rows)
        var inserted = Todo(title: "Fresh top task"); inserted.status = "running"
        tasks.insert(inserted, at: 0)
        rows = page(revision: 1)
        precondition(ids(rows) == reading, "New tasks must preserve the exact old page while reading")
        let removedFirst = reading.first!, removedLast = reading.last!
        tasks.removeAll { $0.id == removedFirst || $0.id == removedLast }
        rows = page(revision: 2)
        precondition(ids(rows).contains(reading[100]), "An interior anchor must survive endpoint deletion")
        for _ in 0..<30 { model.loadEarlier(); rows = page(revision: 2); precondition(model.visibleTaskCount <= 240) }
        precondition(!model.hasEarlier && ids(rows).first == inserted.id)
        model.showTop(); rows = page(revision: 2, follow: true)
        precondition(ids(rows) == Array(tasks.prefix(80).map(\.id)))
        precondition(model.visibleTaskCount == 80)
        precondition(!Mirror(reflecting: rows.compactMap(\.task).first!).children.contains { ["messages", "artifacts", "approval"].contains($0.label ?? "") },
                     "Row values must not carry a task's heavyweight payload")
        print("PASS10k Todo: initial80,30 earlier/later page cycles<=240, stable insert/delete anchors, lightweight values and explicit top")

        precondition(ids(page("Historical 中文", revision: 2)) == [tasks.first { $0.title == "Task 9999" }!.id])
        precondition(ids(page("needle-report", revision: 2)) == [tasks.first { $0.title == "Task 9998" }!.id])
        tasks[0].title = "Cross field title"
        tasks[0].messages = [Message(role: "assistant", text: "transcript evidence 中文")]
        precondition(ids(page("Cross evidence 中文", revision: 3)) == [inserted.id], "Query words may span title and transcript fields")
        precondition(page("new exact query", revision: 3).isEmpty)
        tasks[0].summary = "new exact query"
        precondition(ids(page("new exact query", revision: 4)) == [inserted.id], "Same-count metadata updates must invalidate search")
        tasks[0].status = "completed"; tasks[0].completedAt = now
        precondition(ids(page("new exact query", revision: 5)) == [inserted.id], "Todo search intentionally includes completed matches")
        precondition(ids(page("new exact query", done: true, revision: 5)) == [inserted.id])
        precondition(page("Historical 中文", done: true, revision: 5).isEmpty)
        rows = page(done: true, revision: 5)
        precondition(rows.first == .section(.init(id: "today", title: "Today")))
        tasks[0].status = "ready"; tasks[0].completedAt = nil
        precondition(page(done: true, revision: 6).isEmpty)
        precondition(model.totalMatchCount == 0)
        precondition(ids(page(revision: 6, follow: true)).first == inserted.id)
        print("PASS full-history transcript/file/multifield search, existing cross-status Todo search, Completed filter and completion/reopen cache invalidation")

        let completedModel = PicoTaskListIndex()
        let completed = (0..<12_000).map { index -> Todo in
            var task = Todo(title: "Archived \(index)"); task.status = "completed"; task.completedAt = now
            return task
        }
        func completedRows() -> [PicoTaskListRow] {
            completedModel.rows(tasks: completed, revision: 0, completed: true, now: now,
                                calendar: calendar, followsTop: false)
        }
        var archivedRows = completedRows()
        precondition(archivedRows.count == 81 && archivedRows.first == .section(.init(id: "today", title: "Today")))
        for _ in 0..<45 {
            let prior = Set(ids(archivedRows)); completedModel.loadLater(); archivedRows = completedRows()
            precondition(archivedRows.count <= 241 && completedModel.visibleTaskCount <= 240)
            precondition(!prior.intersection(ids(archivedRows)).isEmpty)
            precondition(archivedRows.first == .section(.init(id: "today", title: "Today")), "A page starting mid-section needs its contextual heading")
            precondition(archivedRows.dropFirst().allSatisfy { $0.task != nil }, "Completed must remain flat, not one eager section container")
        }
        precondition(completedModel.totalMatchCount == 12_000)
        print("PASS12k same-day Completed: flat header+task rows, contextual page headings,45 page cycles<=240 tasks")

        let dates: [Date?] = [now, calendar.date(byAdding: .day, value: -1, to: today),
                              calendar.dateInterval(of: .weekOfYear, for: now)!.start,
                              calendar.date(byAdding: .weekOfYear, value: -1, to: calendar.dateInterval(of: .weekOfYear, for: now)!.start),
                              calendar.date(byAdding: .month, value: -2, to: now), nil]
        let dated = dates.enumerated().map { pair -> Todo in
            var task = Todo(title: "Bucket \(pair.offset)"); task.status = "completed"; task.completedAt = pair.element
            return task
        }
        let dateModel = PicoTaskListIndex()
        let groups = CompletionSection.group(dated, now: now, calendar: calendar)
        let grouped = dateModel.rows(tasks: dated, revision: 0, completed: true, now: now, calendar: calendar)
        let actualHeaders = grouped.compactMap { row -> String? in if case .section(let section) = row { return section.title }; return nil }
        precondition(actualHeaders == groups.map(\.title), "Date buckets must preserve the existing product labels and ordering")
        precondition(ids(grouped) == groups.flatMap { $0.tasks.map(\.id) })
        var justToday = Todo(title: "Midnight item"); justToday.status = "completed"; justToday.completedAt = now
        let midnightModel = PicoTaskListIndex()
        precondition(midnightModel.rows(tasks: [justToday], revision: 0, completed: true, now: now, calendar: calendar).first == .section(.init(id: "today", title: "Today")))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        precondition(midnightModel.rows(tasks: [justToday], revision: 0, completed: true, now: tomorrow, calendar: calendar).first == .section(.init(id: "yesterday", title: "Yesterday")), "Midnight refresh must not require a task mutation")
        print("PASS cached Completed groups match legacy semantics, retain undated legacy tasks and advance at midnight")

        // A derived list must not keep a second reference to TaskStore's full
        // array. Otherwise the next one-task status update copies every Todo.
        var mutationTasks = (0..<20_000).map { index -> Todo in
            var task = Todo(title: "Mutation task \(index)"); task.status = "ready"
            return task
        }
        let mutationModel = PicoTaskListIndex()
        func bufferAddress() -> UInt {
            mutationTasks.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress!) }
        }
        let originalBuffer = bufferAddress()
        _ = mutationModel.rows(tasks: mutationTasks, revision: 0, completed: false,
                               now: now, calendar: calendar)
        for index in 0..<50 {
            mutationTasks[index].summary = "Updated summary \(index)"
            precondition(bufferAddress() == originalBuffer,
                         "The lightweight index must not force full-array CoW during a one-task mutation")
            _ = mutationModel.rows(tasks: mutationTasks, revision: index + 1, completed: false,
                                   now: now, calendar: calendar)
        }
        print("PASS20k task array retains its unique backing buffer through50 indexed one-task mutations; no heavyweight source array retained")

        let cacheModel = PicoTaskListIndex()
        var events = 0
        let subscription = cacheModel.objectWillChange.sink { events += 1 }
        let start = Date()
        for _ in 0..<300 {
            _ = cacheModel.rows(tasks: tasks, revision: 6, completed: false, now: now, calendar: calendar)
        }
        let cachedReadTime = Date().timeIntervalSince(start)
        precondition(events == 0, "Body-time cache reads must never publish geometry/view-update feedback")
        cacheModel.loadLater(); precondition(events == 1)
        for index in 0..<25 {
            _ = cacheModel.rows(tasks: tasks, revision: 6, completed: false, query: "Task \(index)", now: now, calendar: calendar)
        }
        let positions = Mirror(reflecting: cacheModel).children.first { $0.label == "positions" }!.value
        precondition(Mirror(reflecting: positions).children.count <= 12)
        withExtendedLifetime(subscription) {}
        precondition(tasks.count == 9999 && Set(tasks.map(\.id)).count == tasks.count)
        print("PASS body reads publish0 updates; navigation publishes1, query scope cache bounded12;300 cached10k reads \(String(format: "%.3f", cachedReadTime))s")
    }
}
