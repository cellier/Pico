import SwiftUI

/// Give light navigation a readable glass edge against the pale window surface.
/// Apply native glass to the complete control, so it cannot sample its own text.
struct PicoHeaderGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    var enabled = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if !enabled {
            content
        } else if colorScheme == .light {
            lightControl(content)
                .overlay {
                    rim
                        .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
                        .allowsHitTesting(false)
                }
        } else {
            content.modifier(GlassSurface(shape: shape, interactive: interactive))
        }
    }

    @ViewBuilder private func lightControl(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    private var rim: some View {
        shape.stroke(
            LinearGradient(stops: [
                .init(color: .white.opacity(0.96), location: 0),
                .init(color: .white.opacity(0.40), location: 0.42),
                .init(color: .black.opacity(0.13), location: 1)
            ], startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: 0.75
        )
    }
}
