import SwiftUI

/// Shared feedback for custom controls. Hover never changes the layout or activates an action.
struct HoverButtonStyle: ButtonStyle {
    var standard = false
    var hoverScale: CGFloat = 1.035
    func makeBody(configuration: Configuration) -> some View {
        HoverButtonLabel(configuration: configuration, standard: standard, hoverScale: hoverScale)
    }
}
private struct HoverButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let standard: Bool
    let hoverScale: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        configuration.label
            .padding(.horizontal, standard ? 10 : 0).padding(.vertical, standard ? 5 : 0)
            .foregroundColor(configuration.role == .destructive ? .red : nil)
            .background(Color.primary.opacity(enabled && configuration.isPressed ? 0.14 : enabled && hovering ? 0.09 : standard ? 0.055 : 0), in: RoundedRectangle(cornerRadius: standard ? 8 : 18))
            .brightness(enabled && hovering ? 0.035 : 0)
            .scaleEffect(reduceMotion || !enabled ? 1 : configuration.isPressed ? 0.96 : hovering ? hoverScale : 1)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: standard ? 8 : 18))
            .onHover { hovering = $0 && enabled }
            .onChange(of: enabled) { _, value in if !value { hovering = false } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
private struct NativeHoverFeedback: ViewModifier {
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.brightness(hovering && enabled ? -0.055 : 0)
            .scaleEffect(hovering && enabled && !reduceMotion ? 1.025 : 1)
            .onHover { hovering = $0 && enabled }
            .onChange(of: enabled) { _, value in if !value { hovering = false } }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovering)
    }
}
extension View {
    func nativeHoverFeedback() -> some View { modifier(NativeHoverFeedback()) }
}
