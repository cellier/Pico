import CoreGraphics
import Foundation
@main struct SelectionTranslationTests {
    static func main() {
        precondition(TranslationTarget.detect("划词之后，出现翻译的小 icon+文字入口") == .english)
        precondition(TranslationTarget.detect("A small icon-plus-text entry point appears.") == .chinese)
        precondition(TranslationTarget.detect("serendipity") == .chinese)
        precondition(TranslationTarget.detect("翻译") == .english)
        precondition(TranslationTarget.detect("我们明天用 Figma 和 SwiftUI 讨论 liquid glass") == .english, "Chinese with English terms is Chinese")
        precondition(TranslationTarget.detect("The word 你好 means hello in Chinese, and it is used every day.") == .chinese, "English with a Chinese term is English")

        let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
        // Accessibility rect (top-left origin) is flipped and kept when the gesture ended inside it.
        let ax = CGRect(x: 100, y: 200, width: 300, height: 40)
        let rect = SelectionTranslationLayout.selectionRect(accessibility: ax, primaryHeight: 900, down: CGPoint(x: 110, y: 690), up: CGPoint(x: 390, y: 670))!
        precondition(rect == CGRect(x: 100, y: 660, width: 300, height: 40))
        // Bounds away from the pointer belong to an older selection (e.g. a window was dragged).
        precondition(SelectionTranslationLayout.selectionRect(accessibility: CGRect(x: 900, y: 0, width: 10, height: 10), primaryHeight: 900, down: CGPoint(x: 100, y: 500), up: CGPoint(x: 300, y: 500)) == nil)
        // Multi-line: the app reports only the first line; the drag ends lines below but started on it.
        let firstLine = CGRect(x: 100, y: 200, width: 500, height: 20)
        precondition(SelectionTranslationLayout.selectionRect(accessibility: firstLine, primaryHeight: 900, down: CGPoint(x: 110, y: 690), up: CGPoint(x: 400, y: 560)) != nil)
        // Apps without bounds fall back to the gesture.
        let fallback = SelectionTranslationLayout.selectionRect(accessibility: nil, primaryHeight: 900, down: CGPoint(x: 100, y: 500), up: CGPoint(x: 300, y: 500))!
        precondition(fallback.midX == 200 && fallback.maxY > 500)

        let button = SelectionTranslationLayout.buttonOrigin(selection: rect, visible: visible)
        precondition(button.x + SelectionTranslationLayout.buttonSize.width / 2 == rect.midX, "Button is centered on the selection")
        precondition(button.y == rect.maxY + 6, "Button sits just above the selection")
        let top = SelectionTranslationLayout.buttonOrigin(selection: CGRect(x: 10, y: 850, width: 50, height: 20), visible: visible)
        precondition(top.y + SelectionTranslationLayout.buttonSize.height <= 850 && top.x >= 4, "Button flips below and stays on screen")

        let below = SelectionTranslationLayout.panelOrigin(selection: rect, visible: visible)
        precondition(below.y + SelectionTranslationLayout.panelSize.height <= rect.minY, "Panel opens below the selection")
        let above = SelectionTranslationLayout.panelOrigin(selection: CGRect(x: 600, y: 100, width: 100, height: 20), visible: visible)
        precondition(above.y >= 120, "Panel opens above a selection near the bottom")

        let prompt = SelectionTranslationContext.prompt(source: "你好", translation: "Hello", target: .english, request: "更正式一点")
        precondition(prompt.contains("你好") && prompt.contains("Hello") && prompt.hasSuffix("更正式一点"))
        print("PASS: language direction, selection rect, button and panel placement, follow-up context")
    }
}
