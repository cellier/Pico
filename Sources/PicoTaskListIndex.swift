import Combine
import Foundation

/// The list never needs a task's transcript, artifacts or approval payload.
struct PicoTaskListItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let summary: String
    let status: String
    let meetingID: UUID?
    let created: Date
    let completedAt: Date?

    init(_ task: Todo) {
        id = task.id; title = task.title; summary = task.summary; status = task.status
        meetingID = task.meetingID; created = task.created; completedAt = task.completedAt
    }
}

struct PicoTaskListSection: Equatable, Identifiable {
    let id: String
    let title: String
}

enum PicoTaskListRow: Identifiable, Equatable {
    case section(PicoTaskListSection)
    case task(PicoTaskListItem)

    var id: String {
        switch self {
        case .section(let section): return "section:" + section.id
        case .task(let task): return "task:" + task.id.uuidString
        }
    }
    var task: PicoTaskListItem? { if case .task(let item) = self { return item }; return nil }
}

/// Cached lightweight projection, full-history search and bounded display pages.
/// The underlying TaskStore remains the owner of every full task and its data.
@MainActor final class PicoTaskListIndex: ObservableObject {
    @Published private(set) var navigationRevision = 0
    private let pageSize = 80
    private let maximumTasks = 240
    private let maximumScopes = 12
    private var sourceRevision: Int?
    private var items: [PicoTaskListItem] = []

    private struct Scope: Hashable { let completed: Bool; let query: String }
    private struct Position {
        var range: Range<Int>
        var ids: [UUID]
        var followingTop: Bool
        var lastFollowingInput: Bool
    }
    private struct ResultsKey: Hashable {
        let scope: Scope
        let day: Date
        let calendar: Calendar
    }
    private var resultCache: [ResultsKey: [PicoTaskListItem]] = [:]
    private var resultOrder: [ResultsKey] = []
    private var positions: [Scope: Position] = [:]
    private var scopeOrder: [Scope] = []
    private var activeScope: Scope?
    private var activeResults: [PicoTaskListItem] = []

    var hasEarlier: Bool { (activePosition?.range.lowerBound ?? 0) > 0 }
    var hasLater: Bool { (activePosition?.range.upperBound ?? 0) < activeResults.count }
    var totalMatchCount: Int { activeResults.count }
    var visibleTaskCount: Int { activePosition?.range.count ?? 0 }
    private var activePosition: Position? { activeScope.flatMap { positions[$0] } }

    /// Call once at the start of the list body, before reading the flags above.
    /// A getter updates only plain cache state; it never publishes during layout.
    func rows(tasks: [Todo], revision: Int, completed: Bool, query: String = "",
              now: Date = Date(), calendar: Calendar = .current, followsTop: Bool = true) -> [PicoTaskListRow] {
        if sourceRevision != revision {
            sourceRevision = revision
            items = tasks.map(PicoTaskListItem.init)
            resultCache.removeAll(keepingCapacity: true)
            resultOrder.removeAll(keepingCapacity: true)
        }
        let scope = Scope(completed: completed, query: Self.normalizedQuery(query))
        let key = ResultsKey(scope: scope, day: calendar.startOfDay(for: now), calendar: calendar)
        let matches: [PicoTaskListItem]
        if let cached = resultCache[key] {
            matches = cached
        } else {
            let words = scope.query.split(separator: " ").map(String.init)
            let filtered = tasks.indices.filter { index in
                let task = tasks[index]
                // Preserve existing search: Todo searches all statuses;
                // Completed remains restricted to archived tasks.
                if completed || words.isEmpty {
                    guard (task.status == "completed") == completed else { return false }
                }
                return words.allSatisfy { word in
                    task.title.localizedStandardContains(word) || task.summary.localizedStandardContains(word)
                    || task.messages.contains { $0.text.localizedStandardContains(word) }
                    || task.artifacts.contains { $0.name.localizedStandardContains(word) }
                }
            }.map { items[$0] }
            matches = completed ? Self.orderedCompleted(filtered, now: now, calendar: calendar) : filtered
            resultCache[key] = matches
        }
        resultOrder.removeAll { $0 == key }; resultOrder.append(key)
        while resultOrder.count > maximumScopes { resultCache.removeValue(forKey: resultOrder.removeFirst()) }

        var position: Position
        if var existing = positions[scope] {
            if !followsTop { existing.followingTop = false }
            else if !existing.lastFollowingInput { existing.followingTop = true }
            existing.lastFollowingInput = followsTop
            existing.range = existing.followingTop && followsTop
                ? 0..<min(pageSize, matches.count) : reconciled(existing, matches: matches)
            position = existing
        } else {
            position = Position(range: 0..<min(pageSize, matches.count), ids: [],
                                followingTop: followsTop, lastFollowingInput: followsTop)
        }
        rememberIDs(&position, matches: matches)
        positions[scope] = position
        activeScope = scope; activeResults = matches
        touch(scope)
        let visible = Array(matches[position.range])
        guard completed else { return visible.map(PicoTaskListRow.task) }
        // Flatten headers and rows: a large date section must never wrap its
        // tasks in an eager VStack, including when this page begins mid-section.
        var rows: [PicoTaskListRow] = []
        var previous: Int?
        let cutoffs = Cutoffs(now: now, calendar: calendar)
        for item in visible {
            let bucket = cutoffs.bucket(item)
            if previous != bucket { rows.append(.section(Self.sections[bucket])); previous = bucket }
            rows.append(.task(item))
        }
        return rows
    }

    func loadEarlier() {
        guard let scope = activeScope, var position = positions[scope], position.range.lowerBound > 0 else { return }
        let lower = max(0, position.range.lowerBound - pageSize)
        position.range = lower..<min(position.range.upperBound, lower + maximumTasks)
        position.followingTop = false
        rememberIDs(&position, matches: activeResults); positions[scope] = position
        navigationRevision &+= 1
    }
    func loadLater() {
        guard let scope = activeScope, var position = positions[scope], position.range.upperBound < activeResults.count else { return }
        let upper = min(activeResults.count, position.range.upperBound + pageSize)
        position.range = max(position.range.lowerBound, upper - maximumTasks)..<upper
        position.followingTop = false
        rememberIDs(&position, matches: activeResults); positions[scope] = position
        navigationRevision &+= 1
    }
    func showTop() {
        guard let scope = activeScope, var position = positions[scope] else { return }
        position.range = 0..<min(pageSize, activeResults.count)
        position.followingTop = true
        rememberIDs(&position, matches: activeResults); positions[scope] = position
        navigationRevision &+= 1
    }

    private func reconciled(_ position: Position, matches: [PicoTaskListItem]) -> Range<Int> {
        guard !matches.isEmpty else { return 0..<0 }
        guard let first = position.ids.first, let last = position.ids.last else { return 0..<min(pageSize, matches.count) }
        let old = position.range
        if old.upperBound <= matches.count, !old.isEmpty,
           matches[old.lowerBound].id == first, matches[old.upperBound - 1].id == last { return old }
        let lower = matches.firstIndex { $0.id == first }
        let upper = matches.lastIndex { $0.id == last }.map { $0 + 1 }
        if let lower, let upper, lower < upper { return lower..<min(upper, lower + maximumTasks) }
        let count = min(maximumTasks, max(pageSize, position.ids.count))
        if let lower { return lower..<min(matches.count, lower + count) }
        if let upper { return max(0, upper - count)..<upper }
        let indices = Dictionary(uniqueKeysWithValues: matches.enumerated().map { ($0.element.id, $0.offset) })
        for (relative, id) in position.ids.enumerated() {
            if let index = indices[id] {
                let start = max(0, index - relative)
                return start..<min(matches.count, start + count)
            }
        }
        let start = min(max(0, old.lowerBound), max(0, matches.count - count))
        return start..<min(matches.count, start + count)
    }
    private func rememberIDs(_ position: inout Position, matches: [PicoTaskListItem]) {
        let upper = min(matches.count, position.range.upperBound)
        let lower = max(0, min(position.range.lowerBound, upper))
        position.range = lower..<min(upper, lower + maximumTasks)
        position.ids = matches[position.range].map(\.id)
    }
    private func touch(_ scope: Scope) {
        scopeOrder.removeAll { $0 == scope }; scopeOrder.append(scope)
        while scopeOrder.count > maximumScopes {
            let removable = scopeOrder.firstIndex { $0 != scope && !$0.query.isEmpty }
                ?? scopeOrder.firstIndex { $0 != scope }!
            positions.removeValue(forKey: scopeOrder.remove(at: removable))
        }
    }

    private static let sections = [
        PicoTaskListSection(id: "today", title: "Today"),
        PicoTaskListSection(id: "yesterday", title: "Yesterday"),
        PicoTaskListSection(id: "this-week", title: "This Week"),
        PicoTaskListSection(id: "last-week", title: "Last Week"),
        PicoTaskListSection(id: "earlier", title: "Earlier"),
        PicoTaskListSection(id: "undated", title: "Completed Earlier")
    ]
    static func normalizedQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    static func scopeID(completed: Bool, query: String) -> String {
        let normalized = normalizedQuery(query)
        return (completed ? "completed" : "todo") + (normalized.isEmpty ? "" : ":search:" + normalized)
    }
    static func taskRowID(_ id: UUID) -> String { "task:" + id.uuidString }

    private struct Cutoffs {
        let today: Date
        let yesterday: Date
        let week: Date
        let lastWeek: Date
        init(now: Date, calendar: Calendar) {
            today = calendar.startOfDay(for: now)
            yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
            week = calendar.dateInterval(of: .weekOfYear, for: now)!.start
            lastWeek = calendar.date(byAdding: .weekOfYear, value: -1, to: week)!
        }
        func bucket(_ item: PicoTaskListItem) -> Int {
            guard let date = item.completedAt else { return 5 }
            if date >= today { return 0 }
            if date >= yesterday { return 1 }
            if date >= week { return 2 }
            if date >= lastWeek { return 3 }
            return 4
        }
    }
    private static func orderedCompleted(_ tasks: [PicoTaskListItem], now: Date, calendar: Calendar) -> [PicoTaskListItem] {
        let cutoffs = Cutoffs(now: now, calendar: calendar)
        return tasks.enumerated().map { (bucket: cutoffs.bucket($0.element), offset: $0.offset, item: $0.element) }
            .sorted { left, right in
                if left.bucket != right.bucket { return left.bucket < right.bucket }
                let leftDate = left.item.completedAt ?? .distantPast
                let rightDate = right.item.completedAt ?? .distantPast
                return leftDate == rightDate ? left.offset < right.offset : leftDate > rightDate
            }.map(\.item)
    }
}
