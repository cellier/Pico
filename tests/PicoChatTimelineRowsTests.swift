import Foundation

/// Exercise the data used by the real lazy bubble timeline without creating a UI,
/// starting a worker or touching a persisted conversation.
@main struct PicoChatTimelineRowsTests {
    @MainActor static func main() {
        testLongRowsAndOwnership()
        testInlineAttachments()
        testBubbleRunsAndTimestamps()
        testPagedTimestampBoundaries()
        testMarkdownBlocks()
        testFinalArtifacts()
        testStreamingRows()
        testLargeHistory()
        print("PASS: exact long-message copies; inline attachment positions and filenames; bounded stable rows; bubble runs and timestamp boundaries; bold/bullet/number blocks; final-only named files; prefix-stable Markdown streaming; 10k descriptors")
    }

    private enum DisplayPart: Equatable {
        case text(String)
        case file(String)
    }

    private static func displayParts(_ rows: [PicoChatTimelineRowDescriptor]) -> [DisplayPart] {
        rows.flatMap { row -> [DisplayPart] in
            if let parts = row.inlineParts {
                return parts.map { part in
                    switch part {
                    case .text(let text): return .text(text)
                    case .file(let file): return .file(file.path)
                    }
                }
            }
            let text: [DisplayPart] = row.text.isEmpty ? [] : [.text(row.text)]
            return text + row.files.map { .file($0.path) }
        }
    }

    private static func testInlineAttachments() {
        let first = ComposerFile(name: "capture.png", path: "attachments/0-capture.png")
        let second = ComposerFile(name: "notes.pdf", path: "attachments/1-notes.pdf")
        let date = Date(timeIntervalSince1970: 1_792_800_000)
        let text = "先看[Attachment: capture.png]这张图，再看[Attachment: notes.pdf]这份文档。"
        let message = Message(role: "user", text: text, files: [first, second], date: date)
        let rows = PicoChatTimelineRows.build(messages: [message])
        precondition(displayParts(rows) == [.text("先看"), .file(first.path), .text("这张图，再看"), .file(second.path), .text("这份文档。")],
                     "Each real attachment must replace its marker at the original text position")
        precondition(rows.count == 1 && !rows[0].isSplit && rows[0].inlineParts?.count == 5,
                     "A short attachment message must be one naturally sized bubble, not full-width split rows")
        precondition(rows.flatMap(\.files).map(\.path) == [first.path, second.path])
        precondition(rows.allSatisfy { $0.ownerMessageID == message.id && $0.fullMessageText == text },
                     "Presentation must preserve the original transcript and full-message copy")
        precondition(rows.filter(\.isFirst).count == 1 && rows.first?.isFirst == true)
        precondition(rows.filter(\.isLast).count == 1 && rows.last?.isLast == true)
        precondition(rows.filter(\.showsTimestamp).count == 1 && rows.first?.placement.timestamp == date)
        precondition(rows.filter(\.showsTail).count == 1 && rows.last?.showsTail == true,
                     "File rows remain part of the same continuous bubble and time segment")
        precondition(PicoChatTimelineRows.build(messages: [message]).map(\.id) == rows.map(\.id))

        let duplicate = ComposerFile(name: first.name, path: "attachments/2-capture.png")
        let sameNames = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: "[Attachment: capture.png][Attachment: capture.png]", files: [first, duplicate])
        ])
        precondition(sameNames.count == 1 && sameNames[0].text.isEmpty && !sameNames[0].isSplit)
        precondition(displayParts(sameNames) == [.file(first.path), .file(duplicate.path)])
        precondition(sameNames.flatMap(\.files).map(\.path) == [first.path, duplicate.path],
                     "Repeated filenames must resolve to their own saved file in order")

        let shortName = ComposerFile(name: "plan", path: "attachments/plan")
        let bracketName = ComposerFile(name: "plan] draft [final].pdf", path: "attachments/bracket.pdf")
        let bracketRows = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: "[Attachment: plan] draft [final].pdf]然后[Attachment: plan]", files: [shortName, bracketName])
        ])
        precondition(bracketRows.flatMap(\.files).map(\.path) == [bracketName.path, shortName.path],
                     "Complete filenames containing brackets must not be confused with a shorter marker prefix")
        precondition(bracketRows.map(\.text).joined() == "然后")

        let reversed = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: "[Attachment: notes.pdf]再[Attachment: capture.png]", files: [first, second])
        ])
        precondition(reversed.flatMap(\.files).map(\.path) == [second.path, first.path],
                     "Text marker positions determine presentation, not an attachment footer's array order")

        let literal = "解释 [Attachment: missing.png] 这种格式"
        let ordinary = PicoChatTimelineRows.build(messages: [Message(role: "user", text: literal)])
        precondition(ordinary.map(\.text).joined() == literal && ordinary.flatMap(\.files).isEmpty)
        let unknown = PicoChatTimelineRows.build(messages: [Message(role: "user", text: literal, files: [first])])
        precondition(unknown.map(\.text).joined() == literal && unknown.last?.files.first?.path == first.path,
                     "Unmatched literal text must survive even when a different real file is attached")
        let exhausted = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: "[Attachment: capture.png]引用 [Attachment: capture.png]", files: [first])
        ])
        precondition(exhausted.flatMap(\.files).count == 1 && exhausted.map(\.text).joined() == "引用 [Attachment: capture.png]",
                     "A marker without another corresponding file must not duplicate the original attachment")

        let onlyFile = PicoChatTimelineRows.build(messages: [Message(role: "user", text: "[Attachment: capture.png]", files: [first])])
        precondition(onlyFile.count == 1 && onlyFile[0].text.isEmpty && onlyFile[0].files.first?.path == first.path)
        precondition(!onlyFile[0].isSplit && onlyFile[0].showsTail)
        let legacy = PicoChatTimelineRows.build(messages: [Message(role: "user", text: "Old message", files: [first, second])])
        precondition(legacy.count == 1 && legacy[0].text == "Old message" && legacy[0].files.map(\.path) == [first.path, second.path])
        let legacyOnly = PicoChatTimelineRows.build(messages: [Message(role: "user", text: "", files: [first])])
        precondition(legacyOnly.count == 1 && legacyOnly[0].text.isEmpty && legacyOnly[0].files.first?.path == first.path)

        let before = String(repeating: "中英文 🦜 line\n", count: 500)
        let after = String(repeating: "后续说明 ", count: 600)
        let long = before + "[Attachment: capture.png]" + after
        let longRows = PicoChatTimelineRows.build(messages: [Message(role: "user", text: long, files: [first])])
        let fileIndex = longRows.firstIndex { !$0.files.isEmpty }!
        precondition(longRows[..<fileIndex].map(\.text).joined() == before)
        precondition(longRows[(fileIndex + 1)...].map(\.text).joined() == after)
        precondition(longRows.allSatisfy { $0.text.count <= MessageTextLayout.blockLimit && $0.fullMessageText == long },
                     "Attachments must be parsed before bounded text chunking, including across a block boundary")
        precondition(longRows.flatMap(\.files).map(\.path) == [first.path])
        precondition(longRows.count > 1 && longRows.allSatisfy { $0.inlineParts == nil && $0.isSplit },
                     "Long attachment messages must retain bounded lazy rows instead of one large native text layout")

        let atLimit = String(repeating: "🦜", count: MessageTextLayout.blockLimit / 2)
        let shortLimit = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: atLimit + "[Attachment: capture.png]", files: [first])
        ])
        precondition(shortLimit.count == 1 && !shortLimit[0].isSplit && shortLimit[0].inlineParts?.count == 2,
                     "The compact bubble text budget is measured in UTF-16, including emoji")
        let overLimit = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: atLimit + "🦜[Attachment: capture.png]", files: [first])
        ])
        precondition(overLimit.count > 1 && overLimit.allSatisfy { $0.inlineParts == nil && $0.isSplit })

        let manyFiles = (0..<25).map { ComposerFile(name: "input-\($0).txt", path: "attachments/\($0).txt") }
        let maxCompactFiles = Array(manyFiles.prefix(24))
        let compactFileText = maxCompactFiles.map { "[Attachment: " + $0.name + "]" }.joined()
        let compactFiles = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: compactFileText, files: maxCompactFiles)
        ])
        precondition(compactFiles.count == 1 && !compactFiles[0].isSplit && compactFiles[0].inlineParts?.count == 24,
                     "Up to 24 content parts may share one compact bubble")
        let manyFileText = manyFiles.map { "[Attachment: " + $0.name + "]" }.joined()
        let pagedFiles = PicoChatTimelineRows.build(messages: [
            Message(role: "user", text: manyFileText, files: manyFiles)
        ])
        precondition(pagedFiles.count == 25 && pagedFiles.allSatisfy { $0.inlineParts == nil && $0.isSplit },
                     "More than 24 attachment parts must stay in lazy rows, even without text")
        precondition(pagedFiles.flatMap(\.files).map(\.path) == manyFiles.map(\.path))
        precondition(pagedFiles.filter(\.showsTail).count == 1 && pagedFiles.last?.showsTail == true)
    }

    private static func testLongRowsAndOwnership() {
        let attachment = ComposerFile(name: "input.png", path: "/private/input.png")
        let output = Artifact(path: "/private/output.md", name: "output.md")
        // A single-line-break paragraph still preserves every displayed byte.
        let longText = String(repeating: "中文 mixed English line with exact whitespace.\n", count: 2500)
        precondition(longText.count > 100_000)
        let assistant = Message(role: "assistant", text: longText, artifacts: [output])
        let user = Message(role: "user", text: longText, files: [attachment])
        let followup = Message(role: "assistant", text: "A later reply with no files.")
        let rows = PicoChatTimelineRows.build(messages: [assistant, user, followup])
        let assistantRows = rows.filter { $0.ownerMessageID == assistant.id }
        let userRows = rows.filter { $0.ownerMessageID == user.id }
        for pieces in [assistantRows, userRows] {
            precondition(pieces.count > 40)
            precondition(pieces.map(\.text).joined() == longText, "Single-newline chunking lost content")
            precondition(pieces.allSatisfy { $0.text.count <= MessageTextLayout.blockLimit })
            precondition(pieces.first?.isFirst == true && pieces.last?.isLast == true)
            precondition(pieces.dropFirst().allSatisfy { !$0.isFirst })
            precondition(pieces.dropLast().allSatisfy { !$0.isLast && !$0.showsTail })
            precondition(pieces.last?.showsTail == true, "Only the final piece may own the run's tail")
            precondition(pieces.allSatisfy { $0.isSplit && $0.fullMessageText == longText })
        }
        precondition(assistantRows.dropLast().allSatisfy { $0.artifacts.isEmpty && $0.files.isEmpty })
        precondition(assistantRows.last?.artifacts.map(\.path) == [output.path])
        precondition(userRows.dropLast().allSatisfy { $0.artifacts.isEmpty && $0.files.isEmpty })
        precondition(userRows.last?.files.map(\.path) == [attachment.path])
        precondition(rows.filter { !$0.artifacts.isEmpty }.count == 1 && rows.filter { !$0.files.isEmpty }.count == 1)
        precondition(rows.last?.ownerMessageID == followup.id, "Files moved after a later message")
        precondition(assistantRows.allSatisfy(\.markdown) && userRows.allSatisfy { !$0.markdown })
        precondition(Set(rows.map(\.id)).count == rows.count)
        precondition(PicoChatTimelineRows.build(messages: [assistant, user, followup]).map(\.id) == rows.map(\.id))

        let empty = Message(role: "assistant", text: "", artifacts: [output])
        let emptyRows = PicoChatTimelineRows.build(messages: [empty])
        precondition(emptyRows.count == 1 && !emptyRows[0].isSplit)
        precondition(emptyRows[0].artifacts.map(\.path) == [output.path])
        let short = PicoChatTimelineRows.build(messages: [Message(role: "user", text: "Short message")])
        precondition(short.count == 1 && !short[0].isSplit && short[0].showsTail)
        precondition(PicoChatTimelineRows.build(messages: [assistant], assistantMarkdown: false).allSatisfy { !$0.markdown })
    }

    private static func testBubbleRunsAndTimestamps() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        let messages = [
            Message(role: "user", text: "First", date: base),
            Message(role: "user", text: "Same sender", date: base.addingTimeInterval(60)),
            Message(role: "assistant", text: "Reply", date: base.addingTimeInterval(120)),
            Message(role: "assistant", text: "Still same segment", date: base.addingTimeInterval(1019)),
            Message(role: "assistant", text: "Exactly fifteen minutes later", date: base.addingTimeInterval(1919)),
            Message(role: "assistant", text: "New calendar day", date: calendar.date(byAdding: .day, value: 1, to: base)!),
        ]
        let placements = PicoChatTimelineRows.placements(for: messages, calendar: calendar)
        precondition(placements.enumerated().filter { $0.element.timestamp != nil }.map(\.offset) == [0, 4, 5],
                     "Timestamp segments must follow a 15-minute pause or a day boundary")
        precondition(placements.map(\.continuesRun) == [false, true, false, true, false, false])
        precondition(placements.map(\.endsRun) == [false, true, false, true, true, true])
        let rows = PicoChatTimelineRows.build(messages: messages)
        precondition(rows.filter(\.showsTimestamp).map(\.ownerMessageID) == [messages[0].id, messages[4].id, messages[5].id])
        precondition(rows.map(\.showsTail) == [false, true, false, true, true, true])

        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let crossDay = [Message(role: "user", text: "Before", date: midnight.addingTimeInterval(-30)),
                        Message(role: "user", text: "After", date: midnight.addingTimeInterval(30))]
        precondition(PicoChatTimelineRows.placements(for: crossDay, calendar: calendar).allSatisfy { $0.timestamp != nil && !$0.continuesRun && $0.endsRun })

        let legacy = [Message(role: "user", text: "Old transcript"), Message(role: "assistant", text: "No saved dates")]
        precondition(PicoChatTimelineRows.build(messages: legacy).allSatisfy { !$0.showsTimestamp },
                     "Legacy messages must not receive invented timestamps")
        let confirmation = PicoChatTimelineRows.build(messages: [Message(role: "confirmation", text: "Approved")])
        precondition(confirmation.count == 1 && !confirmation[0].showsTail && !confirmation[0].markdown)

        let long = Message(role: "assistant", text: String(repeating: "Long dated message.\n", count: 500), date: base)
        let pieces = PicoChatTimelineRows.build(messages: [long])
        precondition(pieces.count > 1 && pieces.filter(\.showsTimestamp).count == 1 && pieces.first?.showsTimestamp == true,
                     "A timestamp belongs above the full bubble, not every chunk")
    }

    private static func testPagedTimestampBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 12))!
        let preceding = Message(role: "user", text: "Before the page", date: base)
        let nearby = Message(role: "user", text: "First visible message", date: base.addingTimeInterval(60))
        let continued = PicoChatTimelineRows.placements(for: [nearby], precedingMessage: preceding, calendar: calendar)
        precondition(continued[0].timestamp == nil && continued[0].continuesRun,
                     "A page boundary must not create a timestamp or split one sender's run")
        precondition(PicoChatTimelineRows.build(messages: [nearby], precedingMessage: preceding).allSatisfy { !$0.showsTimestamp },
                     "The shared row builder must retain the predecessor's time segment")
        precondition(PicoChatTimelineRows.build(messages: [nearby]).first?.showsTimestamp == true,
                     "A standalone search result or the real conversation start still needs its own time")

        let reply = Message(role: "assistant", text: "Other sender", date: base.addingTimeInterval(120))
        let otherSender = PicoChatTimelineRows.placements(for: [reply], precedingMessage: preceding, calendar: calendar)[0]
        precondition(otherSender.timestamp == nil && !otherSender.continuesRun,
                     "Switching sender at a page boundary must not manufacture a time segment")
        let delayed = Message(role: "user", text: "After a pause", date: base.addingTimeInterval(PicoChatTimelineRows.segmentGap))
        precondition(PicoChatTimelineRows.placements(for: [delayed], precedingMessage: preceding, calendar: calendar)[0].timestamp == delayed.date,
                     "A real fifteen-minute pause must remain visible at a page boundary")

        let midnight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        let beforeMidnight = Message(role: "user", text: "Yesterday", date: midnight.addingTimeInterval(-30))
        let afterMidnight = Message(role: "user", text: "Today", date: midnight.addingTimeInterval(30))
        precondition(PicoChatTimelineRows.placements(for: [afterMidnight], precedingMessage: beforeMidnight, calendar: calendar)[0].timestamp == afterMidnight.date,
                     "Crossing a calendar day must open a segment even when the gap is short")
        let legacy = Message(role: "user", text: "No saved date")
        precondition(PicoChatTimelineRows.placements(for: [nearby], precedingMessage: legacy, calendar: calendar)[0].timestamp == nearby.date,
                     "The first dated message after legacy history must still open a time segment")
        precondition(PicoChatTimelineRows.placements(for: [legacy], precedingMessage: preceding, calendar: calendar)[0].timestamp == nil,
                     "A dated predecessor must never assign its time to an undated message")
    }

    private static func testMarkdownBlocks() {
        let blocks = PicoMessageBlocks.parse("**Key fact**\n\n- First item\n  - Nested item\n1. First step\n2) Second step")
        precondition(blocks == [.text("**Key fact**"), .gap,
                                .item(marker: "•", text: "First item", level: 0),
                                .item(marker: "•", text: "Nested item", level: 1),
                                .item(marker: "1.", text: "First step", level: 0),
                                .item(marker: "2.", text: "Second step", level: 0)],
                     "Bold source and hanging-indent list structure must survive parsing")
        precondition(PicoMessageBlocks.parse("中文 **重点** and English\nsecond line") == [.text("中文 **重点** and English\nsecond line")])
        let text = "**Important**\n\n- Finding\n1. Next step"
        let assistant = PicoChatTimelineRows.build(messages: [Message(role: "assistant", text: text)])
        let user = PicoChatTimelineRows.build(messages: [Message(role: "user", text: text)])
        precondition(assistant.allSatisfy(\.markdown) && user.allSatisfy { !$0.markdown })
        precondition(assistant.allSatisfy { $0.fullMessageText == text } && user.allSatisfy { $0.fullMessageText == text })
    }

    private static func testFinalArtifacts() {
        let draft = Artifact(path: "/private/draft.html", name: "draft.html")
        let result = Artifact(path: "/private/report.pdf", name: "report.pdf")
        let thumbnail = Artifact(path: "/private/thumb.png", name: "thumb.png")
        let resultAgain = Artifact(path: result.path, name: result.name)
        let message = Message(role: "assistant", text: "完成了：[report.pdf](report.pdf)。", artifacts: [draft, result, thumbnail, resultAgain])
        let rows = PicoChatTimelineRows.build(messages: [message])
        precondition(rows.flatMap(\.artifacts).map(\.path) == [result.path],
                     "An explicitly named final deliverable must exclude drafts and supporting files even when those arrive later")
        precondition(message.artifacts?.count == 4, "Presentation filtering must preserve the saved artifact index")
        let archive = Artifact(path: "/private/assets.zip", name: "assets.zip")
        let multiple = PicoChatTimelineRows.finalArtifacts(text: "交付 report.pdf 和 assets.zip", artifacts: [draft, result, thumbnail, archive])
        precondition(multiple.map(\.path) == [result.path, archive.path], "Multiple explicitly requested outputs must remain accessible")
        precondition(PicoChatTimelineRows.finalArtifacts(text: "No files", artifacts: []).isEmpty)
    }

    private static func testStreamingRows() {
        let cache = PicoChatLiveTimelineRowsCache()
        let liveID = UUID()
        let draft = Artifact(path: "/private/intermediate.png", name: "intermediate.png")
        var liveText = ""
        var previous: [PicoChatTimelineRowDescriptor] = []
        // Completed paragraphs are immutable; only the final, open row reflows.
        // Paragraph layout may normalize a boundary newline; Copy must remain exact.
        for index in 0..<600 {
            liveText += "第\(index)段 **streaming** with English and emoji 🦜👩🏽‍💻.\n\n"
            let current = cache.build(text: liveText, ownerMessageID: liveID, artifacts: [draft])
            precondition(current.map(\.text) == PicoChatTimelineRows.paragraphBlocks(liveText),
                         "Streaming chunks differ from the completed-message layout")
            precondition(current.allSatisfy { $0.markdown && $0.ownerMessageID == liveID && $0.fullMessageText == liveText })
            precondition(current.allSatisfy { $0.artifacts.isEmpty && !$0.showsTimestamp }, "Intermediate outputs or duplicate timestamps leaked into a live reply")
            if previous.count > 1 {
                precondition(Array(current.prefix(previous.count - 1)).map(\.id) == previous.dropLast().map(\.id))
                precondition(Array(current.prefix(previous.count - 1)).map(\.text) == previous.dropLast().map(\.text),
                             "Appending a delta changed a closed row")
            }
            previous = current
        }
        let finished = PicoChatTimelineRows.build(messages: [Message(id: liveID, role: "assistant", text: liveText, artifacts: [draft])])
        precondition(finished.map(\.text) == previous.map(\.text) && finished.map(\.id) == previous.map(\.id),
                     "Finishing a streamed reply changed chunk identities or text")
        precondition(finished.last?.artifacts.map(\.path) == [draft.path], "Completed output should become available after the live phase")

        let replacement = "A replacement, not an append."
        precondition(cache.build(text: replacement, ownerMessageID: liveID).map(\.text).joined() == replacement)
        let nextID = UUID()
        let next = cache.build(text: "New run.", ownerMessageID: nextID)
        precondition(next.count == 1 && next[0].ownerMessageID == nextID && next[0].text == "New run.")
    }

    private static func testLargeHistory() {
        let messages = (0..<10_000).map { Message(role: $0.isMultiple(of: 2) ? "assistant" : "user", text: "Message \($0)") }
        let rows = PicoChatTimelineRows.build(messages: messages)
        precondition(rows.count == messages.count && Set(rows.map(\.id)).count == messages.count)
        precondition(rows.first?.ownerMessageID == messages.first?.id && rows.last?.ownerMessageID == messages.last?.id)
    }
}
