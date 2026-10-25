import Foundation

/// Task-detail history pagination regression. No app, native windows,
/// live data, workers or credential access. Optional argument is copied tasks.json.
@main struct PicoTaskDetailPagingTests {
    @MainActor static func main() throws {
        func exercise(_ rows: [PicoChatTimelineRowDescriptor], label: String) {
            precondition(rows.count > 80)
            let window = PicoChatRowWindow(pageSize: 20, maximumRows: 40)
            var visible = window.rows(all: rows, scope: "history", followsLatest: true)
            precondition(visible.map(\.id) == rows.suffix(20).map(\.id))
            var seen = Set(visible.map(\.id))
            var moves = 0
            while window.hasEarlier {
                let previous = Set(visible.map(\.id))
                window.loadEarlier()
                visible = window.rows(all: rows, scope: "history", followsLatest: false)
                precondition(visible.count <= 40 && !previous.intersection(visible.map(\.id)).isEmpty,
                             "Paging must retain overlap without ever eagerly accumulating all history")
                seen.formUnion(visible.map(\.id)); moves += 1
                precondition(moves <= rows.count, "Earlier pagination failed to make progress")
            }
            precondition(seen == Set(rows.map(\.id)), "Every chunk must remain reachable")
            let historical = visible.map(\.id)
            let appended = rows + PicoChatTimelineRows.build(messages: [Message(role: "assistant", text: "New reply")])
            visible = window.rows(all: appended, scope: "history", followsLatest: false)
            precondition(visible.map(\.id) == historical && window.hasLater,
                         "A new message must not move someone reading older history")
            var laterMoves = 0
            while window.hasLater {
                let previous = Set(visible.map(\.id))
                window.loadLater()
                visible = window.rows(all: appended, scope: "history", followsLatest: false)
                precondition(visible.count <= 40 && !previous.intersection(visible.map(\.id)).isEmpty)
                laterMoves += 1
                precondition(laterMoves <= appended.count, "Newer pagination failed to make progress")
            }
            window.showLatest()
            visible = window.rows(all: appended, scope: "history", followsLatest: true)
            precondition(visible.map(\.id) == appended.suffix(20).map(\.id))
            let next = appended + PicoChatTimelineRows.build(messages: [Message(role: "assistant", text: "Followed reply")])
            visible = window.rows(all: next, scope: "history", followsLatest: true)
            precondition(visible.map(\.id) == next.suffix(20).map(\.id),
                         "Only an already-following reader may follow an arriving message")
            let defaultChat = PicoChatRowWindow()
            precondition(defaultChat.rows(all: rows, scope: "history", followsLatest: true).count == 80,
                         "Ordinary Chat's default page size must remain80")
            for _ in 0..<20 { defaultChat.loadEarlier(); _ = defaultChat.rows(all: rows, scope: "history", followsLatest: false) }
            precondition(defaultChat.rows(all: rows, scope: "history", followsLatest: false).count <= 240)
            print("PASS \(label): all\(rows.count)chunks reachable,20/40 bounded window, overlap, historical append retention, explicit latest and following; Chat80/240 unchanged")
        }
        let text = String(repeating: "A long mixed-language paragraph 中英文 detail history.\n", count: 20_000)
        let source = Message(role: "user", text: text)
        let hugeRows = PicoChatTimelineRows.build(messages: [source])
        precondition(hugeRows.allSatisfy { $0.fullMessageText == text && $0.ownerMessageID == source.id })
        precondition(hugeRows.map(\.text).joined() == text, "Splitting a huge user message must preserve all text")
        precondition(hugeRows.filter(\.isFirst).count == 1 && hugeRows.filter(\.isLast).count == 1,
                     "Only one first edge and one last tail may render for a split message")
        exercise(hugeRows, label: "one huge selectable message")
        testDetailFocus(rows: hugeRows)
        let cache = PicoTaskDetailTimelineCache()
        precondition(cache.rows(messages: [source]).map(\.id) == hugeRows.map(\.id))
        precondition(cache.rows(messages: [source]).allSatisfy { $0.fullMessageText == text })
        testChatMetadataUpdates(cache: cache)
        testLegacyTaskOutputProjection(cache: cache)
        let streamID = UUID(), stream = PicoChatLiveTimelineRowsCache()
        let streamRows = stream.build(text: text, ownerMessageID: streamID)
        exercise(streamRows, label: "one huge streaming reply")
        if let path = CommandLine.arguments.dropFirst().first {
            let url = URL(fileURLWithPath: path), bytes = try Data(contentsOf: url)
            let tasks = try JSONDecoder().decode([Todo].self, from: bytes)
            let task = tasks.filter { $0.meetingID == nil }.max { lhs, rhs in
                lhs.messages.reduce(0) { $0 + $1.text.utf16.count } < rhs.messages.reduce(0) { $0 + $1.text.utf16.count }
            }!
            let rows = cache.rows(messages: task.messages)
            for message in task.messages {
                let pieces = rows.filter { $0.ownerMessageID == message.id }
                precondition(!pieces.isEmpty && pieces.allSatisfy { $0.fullMessageText == message.text },
                             "Each chunk must carry its complete original message for Copy")
            }
            exercise(rows, label: "copied longest saved task")
            let after = try Data(contentsOf: url)
            precondition(after == bytes)
        }
    }

    @MainActor private static func testDetailFocus(rows: [PicoChatTimelineRowDescriptor]) {
        let window = PicoChatRowWindow(pageSize: 20, maximumRows: 40)
        _ = window.rows(all: rows, scope: "history", followsLatest: true)
        for index in [0, 19, 20, rows.count / 2, rows.count - 1] {
            let anchor = rows[index].id
            window.beginLatestJump()
            window.focus(on: anchor, all: rows, scope: "history")
            let focused = window.rows(all: rows, scope: "history", followsLatest: false)
            precondition(focused.count <= 20 && focused.contains { $0.id == anchor },
                         "Cancelling a far jump must keep the reading anchor inside a 20-row task page")
            let appended = rows + PicoChatTimelineRows.build(messages: [Message(role: "assistant", text: "Later reply")])
            let reconciled = window.rows(all: appended, scope: "history", followsLatest: false)
            precondition(reconciled.map(\.id) == focused.map(\.id),
                         "A message arriving after a cancelled jump must not replace the focused reading page")
        }
        print("PASS task focus: 20-row pages preserve start/middle/end reading anchors after cancelled jumps and later appends")
    }

    /// Detail sheets can stay open as a worker completes its response or as old
    /// metadata is reconciled. Cached rows must update their dated run boundaries,
    /// Markdown and linked files without replacing or truncating the saved message.
    @MainActor private static func testChatMetadataUpdates(cache: PicoTaskDetailTimelineCache) {
        let base = Date(timeIntervalSince1970: 1_792_747_200)
        let legacy = [Message(role: "user", text: "Older request"),
                      Message(role: "assistant", text: "Older reply")]
        let firstDated = Message(role: "user", text: "New request", date: base)
        let datedReply = Message(role: "assistant", text: "New reply", date: base.addingTimeInterval(30))
        let mixedRows = cache.rows(messages: legacy + [firstDated, datedReply])
        precondition(mixedRows.filter(\.showsTimestamp).map(\.ownerMessageID) == [firstDated.id],
                     "The first newly dated message after undated history must open a timestamp segment; legacy dates must remain absent and the immediate reply must share the segment")
        var user = Message(role: "user", text: "Please make a report", date: base)
        var reply = Message(role: "assistant", text: "**Summary**\n\n- First finding\n1. Next step", date: base.addingTimeInterval(30))
        var rows = cache.rows(messages: [user, reply])
        precondition(rows.filter(\.showsTimestamp).map(\.ownerMessageID) == [user.id])
        precondition(rows.filter { $0.ownerMessageID == reply.id }.allSatisfy(\.markdown),
                     "Task replies must retain Chat's Markdown rather than reverting to plain text")

        // The same message IDs acquire final outputs and a corrected send time.
        // Their unchanged body text must not make the metadata cache stale.
        let input = ComposerFile(name: "brief.pdf", path: "/private/pico-test/brief.pdf")
        let draft = Artifact(path: "/private/pico-test/draft.html", name: "draft.html")
        let result = Artifact(path: "/private/pico-test/report.pdf", name: "report.pdf")
        let preview = Artifact(path: "/private/pico-test/preview.png", name: "preview.png")
        user.files = [input]
        reply.date = base.addingTimeInterval(PicoChatTimelineRows.segmentGap)
        reply.artifacts = [draft, result, preview]
        rows = cache.rows(messages: [user, reply])
        precondition(rows.filter(\.showsTimestamp).map(\.ownerMessageID) == [user.id, reply.id])
        precondition(rows.flatMap(\.files).map(\.path) == [input.path])
        precondition(rows.flatMap(\.artifacts).map(\.path) == [preview.path],
                     "Unspecified outputs must use Chat's final-file fallback")
        reply.text += "\n\nSee report.pdf."
        rows = cache.rows(messages: [user, reply])
        precondition(rows.flatMap(\.artifacts).map(\.path) == [result.path],
                     "The finished reply's named output must replace intermediate previews")
        precondition(reply.artifacts?.count == 3 && user.files?.count == 1,
                     "Presentation filtering must not alter task files")
        precondition(rows.filter { $0.ownerMessageID == reply.id }.allSatisfy { $0.fullMessageText == reply.text },
                     "Copy must return the entire updated reply, including Markdown source")
        print("PASS task Chat metadata: Markdown, corrected timestamp segments, input attachments, final-only output reconciliation and complete-copy text")
    }

    @MainActor private static func testLegacyTaskOutputProjection(cache: PicoTaskDetailTimelineCache) {
        let earlier = Artifact(path: "/private/pico-test/earlier.pdf", name: "earlier.pdf")
        let draft = Artifact(path: "/private/pico-test/draft.html", name: "draft.html")
        let result = Artifact(path: "/private/pico-test/final.pdf", name: "final.pdf")
        let archive = Artifact(path: "/private/pico-test/assets.zip", name: "assets.zip")
        let preview = Artifact(path: "/private/pico-test/preview.png", name: "preview.png")
        let history = Message(role: "assistant", text: "Earlier result", artifacts: [earlier])
        let final = Message(role: "assistant", text: String(repeating: "A completed paragraph.\n\n", count: 200)
                            + "Here are final.pdf and assets.zip.", artifacts: [result])
        let messages = [history, Message(role: "user", text: "Continue"), final]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try! encoder.encode(messages)
        var rows = cache.rows(messages: messages, artifacts: [draft, result, archive, preview, result])
        precondition(rows.filter { $0.ownerMessageID == history.id }.flatMap(\.artifacts).map(\.path) == [earlier.path],
                     "Task-wide files must not be added to older assistant replies")
        let finalRows = rows.filter { $0.ownerMessageID == final.id }
        precondition(finalRows.count > 1 && finalRows.dropLast().allSatisfy { $0.artifacts.isEmpty },
                     "A split reply must display its final files only once, on its final chunk")
        precondition(finalRows.last?.artifacts.map(\.path) == [result.path, archive.path],
                     "Named final files must merge with owned files without duplicates or intermediate outputs")
        precondition(try! encoder.encode(messages) == before,
                     "Legacy projection is presentation-only and must never rewrite saved messages")

        // A worker's output-only update invalidates the cache even if no body or
        // message ID changes. Removing a projection must restore owned files.
        rows = cache.rows(messages: messages, artifacts: [])
        precondition(rows.filter { $0.ownerMessageID == final.id }.flatMap(\.artifacts).map(\.path) == [result.path])
        let replacement = Artifact(path: archive.path, name: "Renamed archive.zip")
        rows = cache.rows(messages: messages, artifacts: [replacement])
        precondition(rows.filter { $0.ownerMessageID == final.id }.flatMap(\.artifacts).map(\.name) == [result.name, replacement.name],
                     "Task file metadata updates must invalidate the projection cache")
        let userOnly = [Message(role: "user", text: "No reply yet")]
        precondition(cache.rows(messages: userOnly, artifacts: [result]).flatMap(\.artifacts).isEmpty,
                     "Outputs must not be falsely assigned to a user message")
        let waiting = messages + [Message(role: "user", text: "Please revise")]
        precondition(cache.rows(messages: waiting, artifacts: [archive]).filter { $0.ownerMessageID == final.id }.flatMap(\.artifacts).map(\.path) == [result.path],
                     "A task ending with a user request must not attach new outputs to the previous reply")
        print("PASS legacy task outputs: final-only last reply projection, split-row ownership, deduplication, output-only cache invalidation and unchanged messages")
    }
}
