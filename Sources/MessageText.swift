import SwiftUI
import AppKit

/// Bound each selectable text layout, without truncating the stored or displayed message.
enum MessageTextLayout {
    static let blockLimit = 2048
    static func blocks(_ text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: blockLimit, limitedBy: text.endIndex) ?? text.endIndex
            if end != text.endIndex,
               let newline = text[start..<end].lastIndex(of: "\n"),
               text.distance(from: start, to: newline) > blockLimit / 2 {
                end = text.index(after: newline)
            }
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}

@MainActor private enum MessageTextCache {
    final class Entry: NSObject {
        let blocks: [AttributedString]
        init(_ blocks: [AttributedString]) { self.blocks = blocks }
    }
    static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.totalCostLimit = 4_000_000
        cache.countLimit = 128
        return cache
    }()
    static func blocks(_ text: String, markdown: Bool) -> [AttributedString] {
        let key = ((markdown ? "md:" : "plain:") + text) as NSString
        if let entry = cache.object(forKey: key) { return entry.blocks }
        let blocks = MessageTextLayout.blocks(text).map { block in
            markdown ? ((try? AttributedString(markdown: block, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(block)) : AttributedString(block)
        }
        cache.setObject(Entry(blocks), forKey: key, cost: text.utf16.count * 4)
        return blocks
    }
}

struct MessageText: View {
    let text: String
    var markdown = true
    var body: some View {
        let blocks = MessageTextCache.blocks(text, markdown: markdown)
        Group {
            if blocks.count <= 1 {
                Text(blocks.first ?? AttributedString("")).textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(blocks.indices, id: \.self) { index in
                        Text(blocks[index]).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .contextMenu {
            Button("Copy full message") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
