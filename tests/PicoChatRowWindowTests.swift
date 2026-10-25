import Combine
import Foundation

@main struct PicoChatRowWindowTests {
    @MainActor static func main() {
        let owner = UUID()
        func row(_ index: Int, text: String? = nil, output: Artifact? = nil) -> PicoChatTimelineRowDescriptor {
            PicoChatTimelineRowDescriptor(id: "chunk-\(index)", ownerMessageID: owner,
                kind: .assistant, markdown: false, text: text ?? "Chunk \(index)",
                fullMessageText: text ?? "Complete source message", isFirst: index == 0,
                isLast: output != nil, files: [], artifacts: output.map { [$0] } ?? [])
        }
        var all = (0..<4560).map { row($0) }
        let window = PicoChatRowWindow()
        var publications = 0
        let observer = window.$revision.sink { _ in publications += 1 }
        defer { withExtendedLifetime(observer) {} }
        var visible = window.rows(all: all, scope: "history", followsLatest: true)
        precondition(visible.map(\.id) == all.suffix(80).map(\.id) && window.hasEarlier && !window.hasLater)
        precondition(publications == 1 && window.revision == 0, "The body getter must never publish")
        for _ in 0..<20 {
            let previous = Set(visible.map(\.id))
            window.loadEarlier()
            // The previous true follow signal can remain until the next frame.
            visible = window.rows(all: all, scope: "history", followsLatest: true)
            precondition(visible.count <= 240 && !previous.intersection(visible.map(\.id)).isEmpty)
        }
        precondition(window.hasEarlier && window.hasLater)
        let reading = visible.map(\.id)
        let revision = window.revision
        let beforeGetterPublications = publications
        let prepended = (-100..<0).map { row($0) } + all
        visible = window.rows(all: prepended, scope: "history", followsLatest: false)
        precondition(visible.map(\.id) == reading, "Prepending chunks must preserve exact reading IDs")
        let evicted = Array(prepended.dropLast(400).dropFirst(300))
        visible = window.rows(all: evicted, scope: "history", followsLatest: false)
        precondition(visible.map(\.id) == reading, "Far-end store-page eviction must preserve the chunk window")
        precondition(window.revision == revision && publications == beforeGetterPublications)
        let interiorAnchor = reading[120]
        let endpointsRemoved = evicted.filter { $0.id != reading.first! && $0.id != reading.last! }
        visible = window.rows(all: endpointsRemoved, scope: "history", followsLatest: false)
        precondition(visible.count <= 240 && visible[120].id == interiorAnchor,
                     "An interior anchor should survive removal of both boundary rows")
        visible = window.rows(all: all, scope: "history", followsLatest: false)
        let unchangedReadingIDs = visible.map(\.id)
        all += [row(4560), row(4561)]
        visible = window.rows(all: all, scope: "history", followsLatest: false)
        precondition(visible.map(\.id) == unchangedReadingIDs && window.hasLater,
                     "An incoming reply must not pull a history reader to the tail")
        for _ in 0..<20 {
            window.loadLater()
            visible = window.rows(all: all, scope: "history", followsLatest: false)
            precondition(visible.count <= 240)
        }
        precondition(!window.hasLater && visible.last?.id == all.last?.id)
        window.showLatest()
        visible = window.rows(all: all, scope: "history", followsLatest: true)
        precondition(visible.count == 80 && visible.map(\.id) == all.suffix(80).map(\.id))
        let priorTail = visible.map(\.id)
        all.append(row(4562))
        visible = window.rows(all: all, scope: "history", followsLatest: true)
        precondition(visible.count == 80 && visible.prefix(79).map(\.id) == priorTail.suffix(79).map { $0 })
        print("PASS4560 chunks:80 initial/tail,20 earlier/later pages<=240, stable prepend/eviction/interior anchors, background append and explicit latest")

        let output = Artifact(path: "result.md", name: "result.md")
        let metadataRevision = window.revision
        let metadataPublications = publications
        all[all.count - 1] = row(4562, text: "New streamed text and complete Copy payload", output: output)
        visible = window.rows(all: all, scope: "history", followsLatest: true)
        precondition(visible.last?.text == "New streamed text and complete Copy payload")
        precondition(visible.last?.fullMessageText == "New streamed text and complete Copy payload")
        precondition(visible.last?.artifacts.first?.path == output.path && visible.last?.isLast == true)
        precondition(visible.last?.ownerMessageID == owner)
        for _ in 0..<100 { _ = window.rows(all: all, scope: "history", followsLatest: true) }
        precondition(window.revision == metadataRevision && publications == metadataPublications,
                     "Same-ID metadata and repeated body reads must not publish")
        print("PASS same-ID live text, Copy payload, final flags and output metadata refresh without body-time publications")

        for _ in 0..<5 {
            window.loadEarlier()
            visible = window.rows(all: all, scope: "history", followsLatest: false)
        }
        let historyIDs = visible.map(\.id)
        var search = window.rows(all: all, scope: "search:alpha", followsLatest: false)
        precondition(search.map(\.id) == all.prefix(80).map(\.id) && !window.hasEarlier && window.hasLater)
        for _ in 0..<5 {
            window.loadLater()
            search = window.rows(all: all, scope: "search:alpha", followsLatest: false)
        }
        let searchIDs = search.map(\.id)
        _ = window.rows(all: all, scope: "search:beta", followsLatest: false)
        precondition(window.rows(all: all, scope: "history", followsLatest: false).map(\.id) == historyIDs)
        precondition(window.rows(all: all, scope: "search:alpha", followsLatest: false).map(\.id) == searchIDs)
        for index in 0..<20 {
            _ = window.rows(all: all, scope: "search:eviction-\(index)", followsLatest: false)
            window.loadLater()
            _ = window.rows(all: all, scope: "search:eviction-\(index)", followsLatest: false)
        }
        precondition(window.rows(all: all, scope: "history", followsLatest: false).map(\.id) == historyIDs,
                     "Search LRU eviction must preserve the history scope")
        precondition(window.rows(all: all, scope: "search:eviction-0", followsLatest: false).count == 80,
                     "Old search snapshots must be evicted from the bounded LRU")
        precondition(window.rows(all: [], scope: "search:empty", followsLatest: false).isEmpty && !window.hasEarlier && !window.hasLater)
        let emptyRevision = window.revision
        window.loadEarlier(); window.loadLater()
        precondition(window.revision == emptyRevision)
        print("PASS independent history/search ranges, first80 search, bounded scope LRU and empty/no-op boundaries")

        // A jump starts from the complete old reading window. A follow signal
        // must not discard those visible rows before the motion can use them.
        _ = window.rows(all: all, scope: "history", followsLatest: false)
        let beforeJump = window.rows(all: all, scope: "history", followsLatest: false).map(\.id)
        window.beginLatestJump()
        visible = window.rows(all: all, scope: "history", followsLatest: true)
        precondition(visible.map(\.id) == beforeJump && visible.count <= 240)
        window.cancelLatestJump()
        visible = window.rows(all: all, scope: "history", followsLatest: false)
        precondition(visible.map(\.id) == beforeJump, "Cancelling must retain the reading window")
        window.beginLatestJump(); window.finishLatestJump()
        visible = window.rows(all: all, scope: "history", followsLatest: true)
        precondition(visible.map(\.id) == all.suffix(80).map(\.id), "Finished motion releases its old rows")
        window.focus(on: all[1234].id, all: all, scope: "history")
        visible = window.rows(all: all, scope: "history", followsLatest: false)
        precondition(visible.count == 80 && visible.contains { $0.id == all[1234].id })
        let resumed = Set(visible.map(\.id))
        window.loadEarlier()
        visible = window.rows(all: all, scope: "history", followsLatest: false)
        precondition(visible.count <= 240 && resumed.isSubset(of: Set(visible.map(\.id))))
        print("PASS jump pins its visible start, cancellation retains it, completion releases it and continuous history resumes around the reading anchor")
    }
}
