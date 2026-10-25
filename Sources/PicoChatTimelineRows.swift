import AppKit
import SwiftUI

/// Preserve attachment positions without forcing a compact message into several
/// full-width layout rows. Long messages still use the bounded row projection.
enum PicoMessageInlinePart {
    case text(String)
    case file(ComposerFile)
}

/// Data-only pieces let the timeline realize a paragraph without constructing
/// every other paragraph in a very long message.
struct PicoChatTimelineRowDescriptor: Identifiable {
    enum Kind { case user, assistant, confirmation }

    /// Where a message sits in the conversation, following Messages: a timestamp
    /// opens each time segment, consecutive messages from one sender stack tightly,
    /// and only the last bubble of such a run carries a tail.
    struct Placement: Equatable {
        var timestamp: Date?
        var continuesRun = false
        var endsRun = true
    }

    let id: String
    let ownerMessageID: UUID
    let kind: Kind
    let markdown: Bool
    let text: String
    let fullMessageText: String
    let isFirst: Bool
    let isLast: Bool
    let files: [ComposerFile]
    let artifacts: [Artifact]
    var placement = Placement()
    var inlineParts: [PicoMessageInlinePart]? = nil

    /// A message split into several rows draws one continuous bubble.
    var isSplit: Bool { !(isFirst && isLast) }
    var showsTimestamp: Bool { isFirst && placement.timestamp != nil }
    var showsTail: Bool { isLast && placement.endsRun && kind != .confirmation }
}

enum PicoChatTimelineRows {
    /// Pico groups consecutive messages into time segments, with a new timestamp
    /// after a 15-minute pause or on a new calendar day.
    static let segmentGap: TimeInterval = 15 * 60

    static func placements(for messages: [Message], precedingMessage: Message? = nil, calendar: Calendar = .current) -> [PicoChatTimelineRowDescriptor.Placement] {
        var result: [PicoChatTimelineRowDescriptor.Placement] = []
        var startsSegment: [Bool] = []
        for (index, message) in messages.enumerated() {
            let previous = index > 0 ? messages[index - 1] : precedingMessage
            // Old task messages have no saved time. The first real timestamp
            // after that legacy history opens a new segment; never invent one.
            var starts = previous == nil || (message.date != nil && previous?.date == nil)
            if let date = message.date, let earlier = previous?.date {
                starts = starts || date.timeIntervalSince(earlier) >= segmentGap || !calendar.isDate(date, inSameDayAs: earlier)
            }
            startsSegment.append(starts)
            let continues = !starts && previous.map { role($0) == role(message) } == true
            result.append(.init(timestamp: starts ? message.date : nil, continuesRun: continues))
        }
        for index in result.indices {
            let next = index + 1 < messages.count ? index + 1 : nil
            result[index].endsRun = next.map { startsSegment[$0] || role(messages[$0]) != role(messages[index]) } ?? true
        }
        return result
    }

    private static func role(_ message: Message) -> String { message.role == "user" ? "user" : message.role == "confirmation" ? "confirmation" : "assistant" }

    /// A reply can produce drafts, previews and supporting assets on its way to the
    /// result. Show the files the reply itself names; otherwise only the last one.
    /// Every file stays in the conversation's folder.
    static func finalArtifacts(text: String, artifacts: [Artifact]) -> [Artifact] {
        var seen = Set<String>()
        let unique = artifacts.reversed().filter { seen.insert($0.path).inserted }.reversed()
        let named = unique.filter { artifact in
            let name = artifact.name.isEmpty ? URL(fileURLWithPath: artifact.path).lastPathComponent : artifact.name
            return !name.isEmpty && text.localizedCaseInsensitiveContains(name)
        }
        if !named.isEmpty { return Array(named) }
        return unique.last.map { [$0] } ?? []
    }

    static func build(messages: [Message], precedingMessage: Message? = nil, assistantMarkdown: Bool = true) -> [PicoChatTimelineRowDescriptor] {
        let placements = placements(for: messages, precedingMessage: precedingMessage)
        return zip(messages, placements).flatMap { message, placement in
            let kind: PicoChatTimelineRowDescriptor.Kind = message.role == "user" ? .user
                : message.role == "confirmation" ? .confirmation : .assistant
            if let files = message.files, !files.isEmpty {
                return attachmentRows(message: message, files: files, kind: kind,
                                      markdown: kind == .assistant && assistantMarkdown, placement: placement)
            }
            let blocks = kind == .assistant ? paragraphBlocks(message.text) : MessageTextLayout.blocks(message.text)
            return describe(pieces: blocks, ownerMessageID: message.id, kind: kind,
                            markdown: kind == .assistant && assistantMarkdown, fullMessageText: message.text,
                            files: message.files ?? [],
                            artifacts: finalArtifacts(text: message.text, artifacts: message.artifacts ?? []),
                            placement: placement)
        }
    }

    private struct AttachmentPiece {
        var text: String
        var files: [ComposerFile]
    }

    /// Inline markers are an internal transcript representation. Replace only
    /// markers backed by the message's own files; ordinary literal text must not
    /// disappear. Matching the complete known filename also handles `]` in names.
    private static func attachmentRows(message: Message, files: [ComposerFile],
                                       kind: PicoChatTimelineRowDescriptor.Kind, markdown: Bool,
                                       placement: PicoChatTimelineRowDescriptor.Placement) -> [PicoChatTimelineRowDescriptor] {
        var indicesByMarker: [String: [Int]] = [:]
        for (index, file) in files.enumerated() {
            indicesByMarker["[Attachment: " + file.name + "]", default: []].append(index)
        }
        // The longer marker wins if one filename is a prefix of another name
        // containing `]`. Same-name files are consumed in their saved order.
        let markers = indicesByMarker.keys.sorted {
            $0.count == $1.count ? $0 < $1 : $0.count > $1.count
        }
        var consumedByMarker: [String: Int] = [:]
        var consumed = Set<Int>()
        var pieces: [AttachmentPiece] = []
        func appendText(_ text: Substring) {
            guard !text.isEmpty else { return }
            let blocks = kind == .assistant ? paragraphBlocks(String(text)) : MessageTextLayout.blocks(String(text))
            pieces.append(contentsOf: blocks.map { AttachmentPiece(text: $0, files: []) })
        }
        let text = message.text
        var cursor = text.startIndex
        var segmentStart = cursor
        while cursor < text.endIndex,
              let prefix = text.range(of: "[Attachment: ", range: cursor..<text.endIndex) {
            let start = prefix.lowerBound
            let marker = markers.first { marker in
                let used = consumedByMarker[marker, default: 0]
                return used < (indicesByMarker[marker]?.count ?? 0) && text[start...].hasPrefix(marker)
            }
            guard let marker, let indices = indicesByMarker[marker] else {
                cursor = prefix.upperBound
                continue
            }
            appendText(text[segmentStart..<start])
            let used = consumedByMarker[marker, default: 0]
            let fileIndex = indices[used]
            consumedByMarker[marker] = used + 1
            consumed.insert(fileIndex)
            pieces.append(AttachmentPiece(text: "", files: [files[fileIndex]]))
            cursor = text.index(start, offsetBy: marker.count)
            segmentStart = cursor
        }
        appendText(text[segmentStart...])
        if pieces.isEmpty { pieces = [AttachmentPiece(text: "", files: [])] }
        // Older transcripts may not have markers. Keep those files accessible
        // inside their own message, after its last text row.
        pieces[pieces.count - 1].files += files.enumerated().compactMap { consumed.contains($0.offset) ? nil : $0.element }
        let artifacts = finalArtifacts(text: text, artifacts: message.artifacts ?? [])
        let textCount = pieces.reduce(0) { $0 + $1.text.utf16.count }
        let partCount = pieces.reduce(0) { $0 + ($1.text.isEmpty ? 0 : 1) + $1.files.count }
        if textCount <= MessageTextLayout.blockLimit && partCount <= 24 {
            let parts = pieces.flatMap { piece -> [PicoMessageInlinePart] in
                let textParts: [PicoMessageInlinePart] = piece.text.isEmpty ? [] : [.text(piece.text)]
                return textParts + piece.files.map { .file($0) }
            }
            return [PicoChatTimelineRowDescriptor(
                id: message.id.uuidString + ":block:0", ownerMessageID: message.id,
                kind: kind, markdown: markdown, text: pieces.map(\.text).joined(),
                fullMessageText: text, isFirst: true, isLast: true,
                files: pieces.flatMap(\.files), artifacts: artifacts,
                placement: placement, inlineParts: parts)]
        }
        return pieces.enumerated().map { index, piece in
            let last = index == pieces.count - 1
            return PicoChatTimelineRowDescriptor(
                id: message.id.uuidString + ":block:" + String(index),
                ownerMessageID: message.id, kind: kind, markdown: markdown, text: piece.text,
                fullMessageText: text, isFirst: index == 0, isLast: last,
                files: piece.files, artifacts: last ? artifacts : [], placement: placement)
        }
    }

    /// Assistant replies are chunked at paragraph breaks instead of only every 2 KB.
    /// Short consecutive paragraphs share a row until it reaches `rowTarget` UTF-16
    /// units; then the row is closed and never changes again. A streaming reply
    /// therefore re-typesets only its open row (about one paragraph plus at most
    /// `rowTarget`) on each flush, while long histories keep a similar row count.
    ///
    /// A break's first newline is dropped at a row boundary because the boundary
    /// already ends the line: "a\n\nb" split across rows renders as "a" + "\nb".
    /// Rows close only at completed paragraphs, so the chunking is prefix-stable:
    /// a live reply and the finished message produce the same rows.
    static func paragraphBlocks(_ text: String, rowTarget: Int = 480) -> [String] {
        var rows: [String] = []
        var open: String?
        func close() { if let row = open { rows.append(row); open = nil } }
        var start = text.startIndex
        var search = start
        var paragraphs: [Substring] = []
        while search < text.endIndex, let range = text.range(of: "\n\n", range: search..<text.endIndex) {
            paragraphs.append(text[start..<range.lowerBound])
            start = text.index(after: range.lowerBound)
            search = range.upperBound
        }
        paragraphs.append(text[start...])
        for (index, paragraph) in paragraphs.enumerated() {
            let blocks = MessageTextLayout.blocks(String(paragraph))
            if blocks.count > 1 {
                // An over-long paragraph keeps the existing 2 KB split as its own rows.
                close(); rows.append(contentsOf: blocks.dropLast()); open = blocks.last
            } else if let row = open {
                // Rejoin with the newline the split dropped.
                open = row + "\n" + (blocks.first ?? "")
            } else {
                open = blocks.first ?? ""
            }
            let isLast = index == paragraphs.count - 1
            if !isLast, let row = open, row.utf16.count >= rowTarget { close() }
        }
        close()
        return rows.isEmpty ? [""] : rows
    }

    fileprivate static func describe(pieces blocks: [String], ownerMessageID: UUID,
                                     kind: PicoChatTimelineRowDescriptor.Kind, markdown: Bool,
                                     fullMessageText: String, files: [ComposerFile], artifacts: [Artifact],
                                     placement: PicoChatTimelineRowDescriptor.Placement = .init()) -> [PicoChatTimelineRowDescriptor] {
        let pieces = blocks.isEmpty ? [""] : blocks
        return pieces.enumerated().map { index, text in
            let last = index == pieces.count - 1
            return PicoChatTimelineRowDescriptor(
                id: ownerMessageID.uuidString + ":block:" + String(index),
                ownerMessageID: ownerMessageID, kind: kind, markdown: markdown, text: text,
                fullMessageText: fullMessageText, isFirst: index == 0, isLast: last,
                files: last ? files : [], artifacts: last ? artifacts : [], placement: placement)
        }
    }
}

/// The completed prefix cannot change while a stream is appended. Rechunk only
/// the open tail; keep the latest complete text available for the Copy action.
final class PicoChatLiveTimelineRowsCache: ObservableObject {
    private var ownerMessageID: UUID?
    private var previousText = ""
    private var previousUTF16Count = 0
    private var prefix: [String] = []
    private var tail = ""

    func build(text: String, ownerMessageID: UUID, files: [ComposerFile] = [], artifacts: [Artifact] = []) -> [PicoChatTimelineRowDescriptor] {
        if self.ownerMessageID != ownerMessageID || text != previousText {
            if self.ownerMessageID == ownerMessageID && text.utf16.starts(with: previousText.utf16) {
                tail += String(decoding: text.utf16.dropFirst(previousUTF16Count), as: UTF16.self)
            } else {
                prefix.removeAll(keepingCapacity: true)
                tail = text
            }
            let pieces = PicoChatTimelineRows.paragraphBlocks(tail)
            prefix.append(contentsOf: pieces.dropLast())
            tail = pieces.last ?? ""
            previousText = text
            previousUTF16Count = text.utf16.count
            self.ownerMessageID = ownerMessageID
        }
        // A reply in progress follows the user's message in the same segment. Files
        // produced along the way stay hidden until the finished reply picks its result.
        return PicoChatTimelineRows.describe(pieces: prefix + [tail], ownerMessageID: ownerMessageID,
                                             kind: .assistant, markdown: true, fullMessageText: text,
                                             files: files, artifacts: [], placement: .init(timestamp: nil, continuesRun: false, endsRun: true))
    }
}

/// Figma "Pico" 353:6035, after Messages: rounded bubbles, a tail on the last
/// bubble of each run, and centered timestamps that open each time segment.
enum PicoMessageMetrics {
    /// Bubbles are translucent white over the window's glass: 20% for the user,
    /// 10% for Pico. Bubble and tail are drawn opaque, then faded together, so
    /// their overlap does not show as a brighter patch.
    static let userBubbleOpacity = 0.2
    static let assistantBubbleOpacity = 0.1
    static let timestamp = TelosTheme.shade(0.43, 0x89 / 255)
    static let dot = TelosTheme.shade(0.42, 0xD9 / 255)
    static let radius: CGFloat = 20
    /// Space between the text and the bubble's top and bottom edges.
    static let verticalPadding: CGFloat = 12
    static let fontSize: CGFloat = 13.5
    /// 18 pt lines for 13.5 pt SF Pro.
    static let lineSpacing: CGFloat = 2
    static let horizontalInset: CGFloat = 8
    /// The opposite side always keeps this much room, as in Messages.
    static let sideRoom: CGFloat = 24
    static let runSpacing: CGFloat = 4
    static let senderSpacing: CGFloat = 20
    static let segmentSpacing: CGFloat = 16
    static let tailOverhang: CGFloat = 5
}

/// Messages' header labels: Today / Yesterday, the weekday within the last week,
/// then the date, with the year once it differs.
enum PicoChatTimestamp {
    static func label(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = format(date, "jmm", calendar)
        if calendar.isDateInToday(date) { return "Today " + time }
        if calendar.isDateInYesterday(date) { return "Yesterday " + time }
        let startOfToday = calendar.startOfDay(for: now)
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday), date >= weekAgo, date < now {
            return format(date, "EEEE", calendar) + " " + time
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return format(date, sameYear ? "EEE, MMM d" : "EEE, MMM d, yyyy", calendar, template: false) + " at " + time
    }
    private static var formatters: [String: DateFormatter] = [:]
    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar, template: Bool = true) -> String {
        let key = pattern + (template ? "#t" : "#f")
        let formatter = formatters[key] ?? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.calendar = calendar
            if template { formatter.setLocalizedDateFormatFromTemplate(pattern) } else { formatter.dateFormat = pattern }
            formatters[key] = formatter
            return formatter
        }()
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }
}

/// The bubble tail from the Figma vector (14 × 11 for Pico; the same shape at
/// 18 × 14, mirrored, for the user's messages).
struct PicoBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 14, sy = rect.height / 11
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(13.3112, 4.61282))
        path.addCurve(to: p(1.86392, 10.3435), control1: p(9.24298, 7.88055), control2: p(6.40117, 9.03878))
        path.addCurve(to: p(1.37107, 9.50132), control1: p(1.39385, 10.4787), control2: p(1.04659, 9.86732))
        path.addCurve(to: p(1.75437, 1.0049), control1: p(3.1769, 7.46438), control2: p(3.7322, 5.33617))
        path.addCurve(to: p(2.33028, 0.340186), control1: p(1.58268, 0.62891), control2: p(1.9367, 0.213912))
        path.addLine(to: p(13.162, 3.81535))
        path.addCurve(to: p(13.3112, 4.61282), control1: p(13.5118, 3.9276), control2: p(13.5977, 4.38272))
        path.closeSubpath()
        return path
    }
}

/// A bubble's fill and optional tail, faded as one layer.
struct PicoBubbleShape: View {
    let isUser: Bool
    let isFirst: Bool
    let isLast: Bool
    let showsTail: Bool
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        let radius = PicoMessageMetrics.radius
        ZStack(alignment: isUser ? .bottomTrailing : .bottomLeading) {
            UnevenRoundedRectangle(
                topLeadingRadius: isFirst ? radius : 0, bottomLeadingRadius: isLast ? radius : 0,
                bottomTrailingRadius: isLast ? radius : 0, topTrailingRadius: isFirst ? radius : 0,
                style: .continuous).fill(TelosTheme.bubbleTint)
            if showsTail {
                if isUser {
                    PicoBubbleTail().fill(TelosTheme.bubbleTint).frame(width: 18, height: 14).scaleEffect(x: -1).offset(x: -6, y: 5)
                } else {
                    PicoBubbleTail().fill(TelosTheme.bubbleTint).frame(width: 14, height: 11).offset(x: 4.66, y: 4)
                }
            }
        }
        .compositingGroup()
        .opacity(colorScheme == .dark
                 ? (isUser ? PicoMessageMetrics.userBubbleOpacity : PicoMessageMetrics.assistantBubbleOpacity)
                 : (isUser ? 0.10 : 0.055))
        .allowsHitTesting(false)
    }
}

/// LoadingThreeBallsBouncing (SwiftfulLoadingIndicators): every quarter second the
/// next ball rises while the others settle, each move easing over half a second.
struct PicoBouncingDots: View {
    var diameter: CGFloat = 6
    var spacing: CGFloat = 4
    var color: Color = PicoMessageMetrics.dot
    var animated = true
    @State private var active = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(color).frame(width: diameter, height: diameter)
                    .offset(y: !animated || reduceMotion ? 0 : (index == active ? -1 : 1) * diameter * 0.33)
                    .opacity(animated && reduceMotion ? (index == active ? 1 : 0.45) : 1)
            }
        }
        .frame(height: diameter * 2)
        .task(id: animated) {
            guard animated else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) { active = (active + 1) % 3 }
            }
        }
        .accessibilityElement().accessibilityLabel("Loading")
    }
}

/// Pico is replying: three bouncing dots in an incoming bubble.
struct PicoTypingIndicator: View {
    var body: some View {
        HStack(spacing: 0) {
            PicoBouncingDots()
                // Figma 353:6192: a 50 × 28 bubble, independent of text-message padding.
                .padding(.horizontal, 12).frame(height: 28)
                .background {
                    PicoBubbleShape(isUser: false, isFirst: true, isLast: true, showsTail: true)
                }
            Spacer(minLength: PicoMessageMetrics.sideRoom)
        }
        .padding(.horizontal, PicoMessageMetrics.horizontalInset)
        .padding(.top, PicoMessageMetrics.senderSpacing)
        .padding(.bottom, PicoMessageMetrics.tailOverhang)
        .accessibilityLabel("Pico is replying")
    }
}

/// Paging older or newer history: smaller, tighter dots with no bubble.
struct PicoHistoryLoading: View {
    var label: String
    var action: () -> Void
    /// Available history is a paging affordance, not an in-progress operation.
    /// Local paging is synchronous; a future asynchronous loader can supply its lifetime.
    var isLoading = false
    var body: some View {
        Button(action: action) {
            PicoBouncingDots(diameter: 3, spacing: 3, animated: isLoading).frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).frame(maxWidth: .infinity).padding(.bottom, 8)
            .accessibilityLabel(label).help(label)
    }
}

/// Inline Markdown (bold, italic, code, links) plus bullet and numbered lists with
/// hanging indents. Blank lines become paragraph spacing.
enum PicoMessageBlocks {
    enum Block: Equatable { case text(String), item(marker: String, text: String, level: Int), gap }
    private static let bullet = try! NSRegularExpression(pattern: #"^[-*•+]\s+(.+)$"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^(\d{1,3})[.)]\s+(.+)$"#)
    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}\s+(.+)$"#)
    private static func captures(_ regex: NSRegularExpression, _ line: String) -> [String]? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }
    }
    static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() { if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let level = min(3, line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2)
            if trimmed.isEmpty {
                flush(); if blocks.last != .gap { blocks.append(.gap) }
            } else if let parts = captures(bullet, trimmed) {
                flush(); blocks.append(.item(marker: "•", text: parts[0], level: level))
            } else if let parts = captures(numbered, trimmed) {
                flush(); blocks.append(.item(marker: parts[0] + ".", text: parts[1], level: level))
            } else if let parts = captures(heading, trimmed) {
                flush(); blocks.append(.text("**" + parts[0] + "**"))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        while blocks.last == .gap { blocks.removeLast() }
        return blocks.isEmpty ? [.text("")] : blocks
    }
}

private struct PicoMessageText: View {
    let text: String
    let markdown: Bool
    var body: some View {
        let blocks = markdown ? PicoMessageBlocks.parse(text) : [.text(text)]
        if blocks.count == 1, case .text(let value) = blocks[0] {
            line(value)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .text(let value): line(value)
                    case .gap: Color.clear.frame(height: 6)
                    case .item(let marker, let value, let level):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(marker).monospacedDigit().frame(minWidth: marker == "•" ? 8 : 14, alignment: .trailing)
                            line(value)
                        }.padding(.leading, CGFloat(level) * 14)
                    }
                }
            }
        }
    }
    private func line(_ value: String) -> some View {
        Text(PicoChatTimelineTextCache.attributed(value, markdown: markdown))
            .lineSpacing(PicoMessageMetrics.lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .scrollTextSelection()
    }
}

/// Construct this view only in the lazy parent's ForEach. The descriptor builder
/// deliberately performs neither Markdown parsing nor SwiftUI layout.
struct PicoChatTimelineRow: View {
    let row: PicoChatTimelineRowDescriptor
    let openAttachment: (ComposerFile) -> Void
    let openArtifact: (Artifact) -> Void
    let artifactsFolderURL: URL

    private var isUser: Bool { row.kind == .user }
    private var topSpacing: CGFloat {
        guard row.isFirst else { return 0 }
        if row.showsTimestamp { return PicoMessageMetrics.segmentSpacing }
        return row.placement.continuesRun ? PicoMessageMetrics.runSpacing : PicoMessageMetrics.senderSpacing
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            if row.showsTimestamp, let date = row.placement.timestamp {
                Text(PicoChatTimestamp.label(for: date))
                    .font(.system(size: 10)).foregroundStyle(PicoMessageMetrics.timestamp)
                    .frame(maxWidth: .infinity).padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            messagePiece
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .padding(.horizontal, PicoMessageMetrics.horizontalInset)
        .padding(.top, topSpacing)
        .padding(.bottom, row.showsTail ? PicoMessageMetrics.tailOverhang : 0)
        .progressiveScrollBlur()
        .accessibilityIdentifier("chatTimelineRow-" + row.id)
    }

    @ViewBuilder private var messagePiece: some View {
        switch row.kind {
        case .confirmation:
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if row.isFirst { Image(systemName: "checkmark.shield") }
                Text(row.text).scrollTextSelection()
            }.font(.system(size: 11)).foregroundStyle(PicoMessageMetrics.timestamp)
                .frame(maxWidth: .infinity)
        case .user, .assistant:
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: PicoMessageMetrics.sideRoom) }
                bubble
                if !isUser { Spacer(minLength: PicoMessageMetrics.sideRoom) }
            }
        }
    }

    private var bubble: some View {
        // Input files occupy their original message position, inside the same
        // bubble as the surrounding text. Generated results stay under the reply.
        VStack(alignment: .leading, spacing: 10) {
            if let parts = row.inlineParts {
                // A compact attachment message has one intrinsic-width bubble.
                // Only genuine long-message chunks need a shared full width.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        switch part {
                        case .text(let text): PicoMessageText(text: text, markdown: row.markdown)
                        case .file(let file): attachment(file)
                        }
                    }
                }
            } else {
                if !row.text.isEmpty || (row.files.isEmpty && row.artifacts.isEmpty) {
                    PicoMessageText(text: row.text, markdown: row.markdown)
                }
                ForEach(Array(row.files.enumerated()), id: \.offset) { _, file in attachment(file) }
            }
            if !row.artifacts.isEmpty {
                PicoArtifactList(artifacts: row.artifacts, folderURL: artifactsFolderURL, openArtifact: openArtifact)
            }
        }
            .font(.system(size: PicoMessageMetrics.fontSize)).foregroundStyle(TelosTheme.primary)
            .padding(.horizontal, 12)
            .padding(.top, row.isFirst ? PicoMessageMetrics.verticalPadding : 0)
            .padding(.bottom, row.isLast ? PicoMessageMetrics.verticalPadding : 0)
            // Rows of one long message share the bubble's full width.
            .frame(maxWidth: row.isSplit ? .infinity : nil, alignment: .leading)
            .background {
                PicoBubbleShape(isUser: isUser, isFirst: row.isFirst, isLast: row.isLast, showsTail: row.showsTail)
            }
            .contextMenu {
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(row.fullMessageText, forType: .string)
                }
            }
    }

    private func attachment(_ file: ComposerFile) -> some View {
        Button { openAttachment(file) } label: {
            Label(file.name, systemImage: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2).truncationMode(.middle)
                .multilineTextAlignment(.leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle(hoverScale: 1))
        .help("Open " + file.name)
        .accessibilityIdentifier("chatAttachment-" + row.id + "-" + file.path)
    }
}

@MainActor private enum PicoChatTimelineTextCache {
    final class Entry: NSObject {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }
    static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 128
        cache.totalCostLimit = 4_000_000
        return cache
    }()
    static func attributed(_ text: String, markdown: Bool) -> AttributedString {
        let key = ((markdown ? "md:" : "plain:") + text) as NSString
        if let cached = cache.object(forKey: key) { return cached.text }
        let value = markdown
            ? ((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            : AttributedString(text)
        cache.setObject(Entry(value), forKey: key, cost: text.utf16.count * 4)
        return value
    }
}
