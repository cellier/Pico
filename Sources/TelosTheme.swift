import AppKit
import SwiftUI

/// Resolve colors from the hosting window, including Pico's saved appearance.
enum TelosTheme {
    static func native(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
    static func shade(_ light: CGFloat, _ dark: CGFloat) -> Color { Color(nsColor: native(light, dark)) }
    static func translucent(_ light: CGFloat, _ dark: CGFloat, lightAlpha: CGFloat, darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
    static let surface = shade(0.985, 0.035)
    static let raised = translucent(0, 1, lightAlpha: 0.045, darkAlpha: 0.06)
    static let bubble = translucent(0, 1, lightAlpha: 0.055, darkAlpha: 0.10)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let contrast = shade(1, 0.08)
    static let bubbleTint = shade(0, 1)
    static let taskBubble = shade(0.90, 30 / 255)
    static let panelTop = translucent(1, 0, lightAlpha: 0.97, darkAlpha: 0.99)
    static let panelMiddle = translucent(0.985, 0, lightAlpha: 0.95, darkAlpha: 0.97)
    static let panelBottom = translucent(0.97, 0, lightAlpha: 0.67, darkAlpha: 0.4)
    static let selectedTabTop = translucent(1, 1, lightAlpha: 0.92, darkAlpha: 0.20)
    static let selectedTabBottom = translucent(1, 1, lightAlpha: 0.75, darkAlpha: 0.12)
    static let selectedTabBorder = translucent(0, 1, lightAlpha: 0.06, darkAlpha: 0.12)
    static let selectedTabShadow = translucent(0, 0, lightAlpha: 0.10, darkAlpha: 0.24)
}
