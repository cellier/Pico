import Combine
import Foundation

/// A bounded realization window inside the already bounded message page. A
/// single message may contain thousands of chunks; only these rows reach SwiftUI.
@MainActor final class PicoChatRowWindow: ObservableObject {
    @Published private(set) var revision = 0

    private struct Position {
        var range: Range<Int>
        var ids: [String]
        var following: Bool
        var lastFollowingInput: Bool
    }
    private let pageSize: Int
    private let maximumRows: Int
    private let maximumScopes = 12
    private var positions: [String: Position] = [:]
    private var scopeOrder: [String] = []
    private var activeScope: String?
    private var allRows: [PicoChatTimelineRowDescriptor] = []
    private var preservingLatestJump = false

    init(pageSize: Int = 80, maximumRows: Int = 240) {
        precondition(pageSize > 0 && maximumRows >= pageSize)
        self.pageSize = pageSize
        self.maximumRows = maximumRows
    }

    var hasEarlier: Bool { (activePosition?.range.lowerBound ?? 0) > 0 }
    var hasLater: Bool { (activePosition?.range.upperBound ?? 0) < allRows.count }
    private var activePosition: Position? { activeScope.flatMap { positions[$0] } }

    /// This getter updates only plain bookkeeping. Publishing here would cause
    /// a view-update loop because it is evaluated from the SwiftUI body.
    func rows(all: [PicoChatTimelineRowDescriptor], scope: String,
              followsLatest: Bool) -> [PicoChatTimelineRowDescriptor] {
        var position: Position
        if let saved = positions[scope] {
            position = saved
            if !followsLatest {
                position.following = false
            } else if !position.lastFollowingInput {
                position.following = true
            }
            position.lastFollowingInput = followsLatest
            if position.following && followsLatest && !preservingLatestJump {
                position.range = latestRange(count: all.count)
            } else {
                position.range = reconciled(position, all: all, scope: scope)
            }
        } else {
            let search = scope.hasPrefix("search:")
            position = Position(range: search ? 0..<min(pageSize, all.count) : latestRange(count: all.count),
                                ids: [], following: !search && followsLatest,
                                lastFollowingInput: followsLatest)
        }
        rememberIDs(&position, all: all)
        positions[scope] = position
        activeScope = scope
        allRows = all
        touch(scope)
        // Always take the fresh descriptors. A live block's text, Copy payload,
        // final-block flags and files can change without changing its row ID.
        return Array(all[position.range])
    }

    func loadEarlier() {
        guard let scope = activeScope, var position = positions[scope], position.range.lowerBound > 0 else { return }
        let lower = max(0, position.range.lowerBound - pageSize)
        position.range = lower..<min(position.range.upperBound, lower + maximumRows)
        position.following = false
        rememberIDs(&position, all: allRows)
        positions[scope] = position
        revision &+= 1
    }

    func loadLater() {
        guard let scope = activeScope, var position = positions[scope], position.range.upperBound < allRows.count else { return }
        let upper = min(allRows.count, position.range.upperBound + pageSize)
        position.range = max(position.range.lowerBound, upper - maximumRows)..<upper
        position.following = false
        rememberIDs(&position, all: allRows)
        positions[scope] = position
        revision &+= 1
    }

    func showLatest() {
        guard let scope = activeScope, var position = positions[scope] else { return }
        position.range = latestRange(count: allRows.count)
        position.following = true
        rememberIDs(&position, all: allRows)
        positions[scope] = position
        revision &+= 1
    }

    /// Keep the visible start of an explicit scroll. Shrinking to the last80
    /// rows before the motion starts would remove the screen we are leaving.
    func beginLatestJump() { preservingLatestJump = true }

    func finishLatestJump() {
        preservingLatestJump = false
        showLatest()
    }

    func cancelLatestJump() {
        preservingLatestJump = false
        guard let scope = activeScope, var position = positions[scope] else { return }
        position.following = false; position.lastFollowingInput = false
        positions[scope] = position
    }

    /// Resume ordinary, contiguous pagination after an interrupted far jump.
    func focus(on id: String, all: [PicoChatTimelineRowDescriptor], scope: String) {
        guard let index = all.firstIndex(where: { $0.id == id }) else { return }
        preservingLatestJump = false
        let lower = max(0, index - min(20, pageSize / 4))
        var position = Position(range: lower..<min(all.count, lower + pageSize), ids: [],
                                following: false, lastFollowingInput: false)
        rememberIDs(&position, all: all)
        positions[scope] = position; activeScope = scope; allRows = all
        touch(scope); revision &+= 1
    }

    private func latestRange(count: Int) -> Range<Int> { max(0, count - pageSize)..<count }

    private func reconciled(_ position: Position, all: [PicoChatTimelineRowDescriptor], scope: String) -> Range<Int> {
        guard !all.isEmpty else { return 0..<0 }
        guard let first = position.ids.first, let last = position.ids.last else {
            return scope.hasPrefix("search:") ? 0..<min(pageSize, all.count) : latestRange(count: all.count)
        }
        let range = position.range
        // The usual append/stream/geometry pass needs no full-list scan.
        if range.lowerBound >= 0, range.upperBound <= all.count, !range.isEmpty,
           all[range.lowerBound].id == first, all[range.upperBound - 1].id == last {
            return range
        }
        let lower = all.firstIndex { $0.id == first }
        let upper = all.lastIndex { $0.id == last }.map { $0 + 1 }
        if let lower, let upper, lower < upper {
            return lower..<min(upper, lower + maximumRows)
        }
        let count = min(maximumRows, max(pageSize, position.ids.count))
        if let lower { return lower..<min(all.count, lower + count) }
        if let upper { return max(0, upper - count)..<upper }
        // A store-page eviction can remove both endpoints while leaving an
        // interior reading anchor. Keep a surviving row at its relative index.
        let indices = all.enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        for (relative, id) in position.ids.enumerated() {
            if let index = indices[id] {
                let start = max(0, index - relative)
                return start..<min(all.count, start + count)
            }
        }
        // No row survives (for example a genuinely changed search result).
        let start = min(max(0, range.lowerBound), max(0, all.count - count))
        return start..<min(all.count, start + count)
    }

    private func rememberIDs(_ position: inout Position, all: [PicoChatTimelineRowDescriptor]) {
        let upper = min(all.count, position.range.upperBound)
        let lower = max(0, min(position.range.lowerBound, upper))
        position.range = lower..<min(upper, lower + maximumRows)
        position.ids = all[position.range].map(\.id)
    }

    private func touch(_ scope: String) {
        scopeOrder.removeAll { $0 == scope }
        scopeOrder.append(scope)
        while scopeOrder.count > maximumScopes {
            let index = scopeOrder.firstIndex { $0 != scope && $0 != "history" }
                ?? scopeOrder.firstIndex { $0 != scope }!
            positions.removeValue(forKey: scopeOrder.remove(at: index))
        }
    }
}
