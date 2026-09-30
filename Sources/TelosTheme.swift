import AppKit
import SwiftUI

/// Dynamic colors preserve the light design and resolve again on system appearance changes.
enum TelosTheme {
    static func native(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
    static func shade(_ light: CGFloat, _ dark: CGFloat) -> Color { Color(nsColor: native(light, dark)) }
    static let surface = shade(1, 0.11)
    static let raised = shade(1, 0.19)
    static let bubble = shade(0.93, 0.23)
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let contrast = shade(1, 0.08)
}
