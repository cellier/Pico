import AppKit
import SwiftUI

@main struct LongContentTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let text = String(repeating: "中英文 long message 👩🏽‍💻 — **important**\n继续下一段，不应该卡住。\n", count: 2500)
        let blocks = MessageTextLayout.blocks(text)
        precondition(blocks.joined() == text, "Chunking must preserve every character")
        precondition(blocks.allSatisfy { $0.count <= MessageTextLayout.blockLimit })
        let unbroken = String(repeating: "👩🏽‍💻", count: 10000)
        precondition(MessageTextLayout.blocks(unbroken).joined() == unbroken)
        precondition(MessageTextLayout.blocks("").isEmpty)

        let draft = ComposerDraft()
        draft.setText(text)
        let start = Date()
        for _ in 0..<1000 { precondition(draft.compactLayoutHeight > 22) }
        precondition(Date().timeIntervalSince(start) < 2, "Hover/focus cannot remeasure the entire draft")
        precondition(draft.text == text)
        draft.setText("Hi")
        precondition(draft.compactLayoutHeight <= 22, "Changing content invalidates the size cache")

        let icon = StatusActivityImageView(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)
        let before = icon.rasterizationCount
        for _ in 0..<1000 { icon.viewDidChangeEffectiveAppearance() }
        precondition(icon.rasterizationCount == before, "Appearance callbacks must not mutate layer contents")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(icon.rasterizationCount == before, "Identical appearances must reuse the rendered icon")
        icon.appearance = NSAppearance(named: .darkAqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(icon.rasterizationCount <= before + 1, "A real theme change redraws at most once")
        print("PASS: full long-message preservation, Unicode boundaries, cached draft sizing, bounded appearance refresh")
    }
}
