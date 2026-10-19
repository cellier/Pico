import SwiftUI
import AppKit

struct GlassCircle<Label: View>: View {
    var help: String
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action) { label().foregroundStyle(TelosTheme.primary).frame(width: 36, height: 36).contentShape(Circle()) }
                .buttonStyle(HoverButtonStyle()).background(TelosTheme.raised.opacity(0.75), in: Circle())
                .glassEffect(.regular.interactive(), in: Circle())
                .help(help).accessibilityLabel(help)
        } else {
            Button(action: action, label: label).buttonStyle(.bordered).nativeHoverFeedback().clipShape(Circle())
                .frame(width: 36, height: 36).help(help).accessibilityLabel(help)
        }
    }
}
extension View {
    @ViewBuilder func inputGlass() -> some View {
        if #available(macOS 26, *) { self.glassEffect(.regular, in: .capsule) }
        else { self.background(.regularMaterial, in: Capsule()).overlay(Capsule().stroke(.gray.opacity(0.2), lineWidth: 0.5)) }
    }
}
struct Composer: View {
    @ObservedObject var draft: ComposerDraft
    var placeholder: String
    var canSend = true
    var identifier: String
    var action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            GlassCircle(help: "Attach files", action: draft.chooseFiles) { Image(systemName: "plus").font(.system(size: 14)) }
            HStack(spacing: 6) {
                AttachmentInput(draft: draft, placeholder: placeholder, identifier: identifier) { if canSend { action() } }
                Button(action: action) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 23)) }
                    .buttonStyle(HoverButtonStyle()).disabled(!canSend || !draft.hasContent || draft.isComposing)
                    .accessibilityLabel("Send").frame(width: 24, height: 23)
                    .opacity(draft.hasContent ? 1 : 0)
                    .allowsHitTesting(draft.hasContent).accessibilityHidden(!draft.hasContent)
            }.padding(.horizontal, 14).padding(.vertical, 9).frame(minHeight: 36)
                .background(ComposerHitArea(draft: draft))
                .inputGlass()
                .overlay(Capsule().stroke(TelosTheme.primary.opacity(draft.isFocused ? 0.38 : (draft.isHovered ? 0.2 : 0)), lineWidth: 1).allowsHitTesting(false))
                .background(TelosTheme.primary.opacity(draft.isPressed ? 0.05 : 0), in: Capsule())
                .onHover { draft.isHovered = $0 }
        }
    }
}
struct MessageBubble: View {
    var text: String
    var body: some View {
        MessageText(text: text, markdown: false).font(.system(size: 14)).lineSpacing(2)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(TelosTheme.shade(0.93, 0.23), in: RoundedRectangle(cornerRadius: 19))
            .overlay(alignment: .bottomTrailing) {
                if let url = Bundle.main.url(forResource: "message-tail", withExtension: "png"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).renderingMode(.template).resizable().foregroundStyle(TelosTheme.bubble).frame(width: 24, height: 14).offset(x: 0, y: 4).allowsHitTesting(false)
                }
            }
    }
}
struct RectPreference: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
extension View {
    func trackRect(_ key: String, in space: String, when tracked: Bool = true) -> some View {
        background {
            if tracked {
                GeometryReader { geo in Color.clear.preference(key: RectPreference.self, value: [key: geo.frame(in: .named(space))]) }
            }
        }
    }
}
struct SendFlight: Identifiable {
    var id = UUID()
    var text: String
    var source: CGRect
    var destination: CGRect
    var target: String
}
struct FlightMotion: AnimatableModifier {
    var progress: CGFloat
    let source: CGRect
    let destination: CGRect
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        let t = min(1, max(0, progress))
        let x = source.midX + (destination.midX-source.midX)*t
        let y = source.midY + (destination.midY-source.midY)*t - sin(t * .pi)*28
        content.frame(width: source.width + (destination.width-source.width)*t)
            .scaleEffect(0.95 + 0.05*t).rotationEffect(.degrees(Double(-sin(t * .pi)*3)))
            .position(x: x, y: y)
    }
}
struct FlightOverlay: View {
    var flight: SendFlight
    var finished: () -> Void
    @State private var progress: CGFloat = 0
    var body: some View {
        MessageBubble(text: String(flight.text.prefix(240))).lineLimit(2)
            .modifier(FlightMotion(progress: progress, source: flight.source, destination: flight.destination))
            .allowsHitTesting(false).accessibilityHidden(true)
            .onAppear {
                withAnimation(.spring(response: 0.48, dampingFraction: 0.82), completionCriteria: .logicallyComplete) { progress = 1 } completion: { finished() }
            }
    }
}

struct BoardSegments: View {
    @Binding var selection: BoardTab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionShape
    var body: some View {
        HStack(spacing: 0) {
            ForEach(BoardTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { selection = tab }
                } label: {
                    Text(tab.rawValue).font(.system(size: 14, weight: .medium)).foregroundStyle(TelosTheme.shade(0.1, 0.92))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background {
                            if selection == tab { Capsule().fill(TelosTheme.shade(0.93, 0.23)).matchedGeometryEffect(id: "selected", in: selectionShape) }
                        }
                        .contentShape(Capsule())
                }.buttonStyle(HoverButtonStyle())
                    .frame(width: tab == .calendar ? 77 : (tab == .tasks ? 47 : 51))
                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                        if tab == .tasks {
                            selection = .tasks
                            DispatchQueue.main.async { NotificationCenter.default.post(name: .init("TelosTaskTop"), object: nil) }
                        }
                    })
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }.padding(4).frame(height: 36)
            .background(TelosTheme.raised.opacity(0.8), in: Capsule())
            .overlay(Capsule().stroke(TelosTheme.primary.opacity(0.08), lineWidth: 0.5))
            .accessibilityElement(children: .contain).accessibilityLabel("View")
    }
}

private struct ScrollEdgeConfiguration {
    var height: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0
}
private struct ScrollEdgeConfigurationKey: EnvironmentKey {
    static let defaultValue = ScrollEdgeConfiguration()
}
private extension EnvironmentValues {
    var scrollEdgeConfiguration: ScrollEdgeConfiguration {
        get { self[ScrollEdgeConfigurationKey.self] }
        set { self[ScrollEdgeConfigurationKey.self] = newValue }
    }
}
/// Blend a soft copy of each rendered item only where it crosses a viewport edge.
/// Native text editors stay outside this effect. The soft copy is noninteractive and hidden from accessibility.
private struct ProgressiveScrollBlur: ViewModifier {
    @Environment(\.scrollEdgeConfiguration) private var edge
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if !reduceTransparency && edge.height > 0 {
            content.mask { edgeMask(inverted: true) }
                .overlay {
                    // Give the blur kernel transparent space around the item. Masking at
                    // the text's original bounds cuts the blur off at the paragraph inset.
                    content.padding(16)
                        .blur(radius: 5)
                        .mask { edgeMask(inverted: false) }
                        .padding(-16)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
        } else { content }
    }
    private func edgeMask(inverted: Bool) -> some View {
        GeometryReader { geometry in
            let y = geometry.frame(in: .scrollView(axis: .vertical)).minY
            let height = max(1, geometry.size.height)
            let positions = ([CGFloat(0), height] + (0...24).flatMap { i in
                let t = CGFloat(i) / 24
                return [edge.top * t - y, edge.height - edge.bottom * t - y]
            }).map { min(height, max(0, $0)) }.sorted()
            LinearGradient(stops: positions.map { position in
                let top = edge.top > 0 ? max(0, min(1, (edge.top - position - y) / (edge.top * 0.55))) : 0
                let bottom = edge.bottom > 0 ? max(0, min(1, (edge.bottom - edge.height + position + y) / (edge.bottom * 0.75))) : 0
                let t = max(top, bottom)
                let amount = t * t * (3 - 2 * t)
                return Gradient.Stop(color: .white.opacity(inverted ? 1 - amount : amount), location: position / height)
            }, startPoint: .top, endPoint: .bottom)
        }
    }
}
extension View {
    func progressiveScrollBlur() -> some View { modifier(ProgressiveScrollBlur()) }
}

struct ScrollEdgeFade: View {
    var top = true
    var whiteSurface = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Group {
            if reduceTransparency || whiteSurface {
                LinearGradient(colors: [TelosTheme.surface, TelosTheme.surface.opacity(0.5), .clear], startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top)
            } else {
                Rectangle().fill(.ultraThinMaterial)
                    .mask(LinearGradient(stops: (0...16).map { index in
                        let t = Double(index) / 16
                        return Gradient.Stop(color: .white.opacity(1 - t * t * (3 - 2 * t)), location: t)
                    }, startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct SoftScrollEdges: ViewModifier {
    let top: CGFloat
    let bottom: CGFloat
    let alwaysTop: Bool
    let alwaysBottom: Bool
    let whiteSurface: Bool
    @State private var overflow = CGSize.zero
    @State private var viewportHeight: CGFloat = 0
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            tracked(content)
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    CGSize(width: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                           height: max(0, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.contentOffset.y - geometry.containerSize.height))
                } action: { _, value in overflow = value }
        } else { edges(content, topOpacity: 1, bottomOpacity: 1) }
    }
    @available(macOS 15, *)
    private func tracked(_ content: Content) -> some View {
        edges(content, topOpacity: alwaysTop ? 1 : min(1, overflow.width / 18), bottomOpacity: alwaysBottom ? 1 : min(1, overflow.height / 18))
    }
    @ViewBuilder private func withoutSystemEdge(_ content: Content) -> some View {
        if #available(macOS 26, *) { content.scrollEdgeEffectHidden() }
        else { content }
    }
    private func edges(_ content: Content, topOpacity: CGFloat, bottomOpacity: CGFloat) -> some View {
        withoutSystemEdge(content)
            .environment(\.scrollEdgeConfiguration, ScrollEdgeConfiguration(height: viewportHeight, top: top * topOpacity, bottom: bottom * bottomOpacity))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .overlay(alignment: .top) { ScrollEdgeFade(whiteSurface: whiteSurface).frame(height: top).opacity(topOpacity) }
            .overlay(alignment: .bottom) { ScrollEdgeFade(top: false, whiteSurface: whiteSurface).frame(height: bottom).opacity(bottomOpacity) }
    }
}
extension View {
    func softScrollEdges(top: CGFloat = 24, bottom: CGFloat = 28, alwaysTop: Bool = false, alwaysBottom: Bool = false, whiteSurface: Bool = false) -> some View {
        modifier(SoftScrollEdges(top: top, bottom: bottom, alwaysTop: alwaysTop, alwaysBottom: alwaysBottom, whiteSurface: whiteSurface))
    }
}

struct TaskComposer: View {
    @ObservedObject var draft: ComposerDraft
    var action: () -> Void
    private var expanded: Bool { !draft.files.isEmpty || draft.compactLayoutHeight > 22 }
    var body: some View {
        AttachmentInput(draft: draft, placeholder: "What would you like to do?", identifier: "newTaskField", action: action)
            .padding(.leading, expanded ? 12 : 44).padding(.trailing, expanded ? 12 : 48)
            .padding(.top, expanded ? 12 : 14).padding(.bottom, expanded ? 52 : 14)
            .frame(minHeight: 48)
            .background(ComposerHitArea(draft: draft))
            .background((draft.isPressed ? TelosTheme.shade(0.96, 0.24) : TelosTheme.raised), in: RoundedRectangle(cornerRadius: expanded ? 20 : 24))
            .overlay(RoundedRectangle(cornerRadius: expanded ? 20 : 24).stroke(TelosTheme.primary.opacity(draft.isFocused ? 0.38 : (draft.isHovered ? 0.2 : 0.09)), lineWidth: 1).allowsHitTesting(false))
            .onHover { draft.isHovered = $0 }
            .overlay(alignment: expanded ? .bottomLeading : .leading) {
                Button(action: draft.chooseFiles) { Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32) }
                    .buttonStyle(HoverButtonStyle()).help("Attach files").padding(.leading, 8).padding(.bottom, expanded ? 8 : 0)
            }
            .overlay(alignment: expanded ? .bottomTrailing : .trailing) {
                if draft.hasContent {
                    Button(action: action) { Image(systemName: "arrow.up").font(.system(size: 18, weight: .medium)).foregroundStyle(TelosTheme.contrast).frame(width: 32, height: 32).background(TelosTheme.primary, in: Circle()) }
                        .buttonStyle(HoverButtonStyle()).disabled(draft.isComposing).accessibilityLabel("Send task").padding(.horizontal, 8).padding(.bottom, expanded ? 8 : 0)
                }
            }
    }
}

/// One persistent surface expands from the search button's left edge.
struct ExpandingSearchControl: View {
    @Binding var active: Bool
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 6) {
            Button {
                active.toggle()
                focused = active
                if !active { text = "" }
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TelosTheme.primary).frame(width: 36, height: 36)
                    .contentShape(Circle())
            }.buttonStyle(HoverButtonStyle(hoverScale: 1))
                .accessibilityLabel(active ? "Close search" : "Search tasks, calendar and feed")
            TextField("Search", text: Binding(get: { active ? text : "" }, set: { if active { text = $0 } }))
                .textFieldStyle(.plain).font(.system(size: 14, weight: .medium))
                .focused($focused).accessibilityIdentifier("headerSearchField")
                .frame(width: 272).opacity(active ? 1 : 0)
                .allowsHitTesting(active).accessibilityHidden(!active)
                .disabled(!active)
                .onExitCommand { active = false; text = "" }
        }
        .frame(width: active ? 330 : 36, height: 36, alignment: .leading)
        .clipped().background(TelosTheme.raised.opacity(0.75), in: Capsule()).inputGlass()
        .animation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.8), value: active)
        .onChange(of: active) { _, value in
            focused = value
            if !value { text = "" }
        }
        .onAppear { focused = active }
    }
}
