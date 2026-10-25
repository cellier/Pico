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
    var isRunning = false
    var stopAction: (() -> Void)? = nil
    var controlSize: CGFloat = 40
    var action: () -> Void
    private var showsAction: Bool { isRunning || draft.hasContent }
    private var showsStop: Bool { isRunning && (!canSend || !draft.hasContent) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            PicoGlassButton(symbol: "plus", size: controlSize, pointSize: 18, help: "Attach files", action: draft.chooseFiles)
                .accessibilityIdentifier(identifier + "-attach")
            HStack(alignment: .bottom, spacing: 4) {
                AttachmentInput(draft: draft, placeholder: placeholder, identifier: identifier) { if canSend { action() } }
                    .frame(maxWidth: .infinity)
                // Keep the text width and single-line height identical before
                // and after Send appears. The action stays on the bottom row.
                Button {
                    if showsStop { stopAction?() } else { action() }
                } label: {
                    Image(systemName: showsStop ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 22)).frame(width: 24, height: 20)
                }
                .buttonStyle(HoverButtonStyle())
                .disabled(showsStop ? stopAction == nil : (!canSend || !draft.hasContent || draft.isComposing))
                .opacity(showsAction ? 1 : 0).allowsHitTesting(showsAction)
                .accessibilityHidden(!showsAction)
                .accessibilityLabel(showsStop ? "Stop" : "Send")
                .accessibilityIdentifier(identifier + "-send")
            }.padding(.leading, 16).padding(.trailing, 8).padding(.vertical, max(0, (controlSize - 20) / 2)).frame(minHeight: controlSize)
                .background(ComposerHitArea(draft: draft))
                .modifier(PicoControlGlass(shape: shape))
                .overlay(shape.stroke(Color.black.opacity(draft.isFocused || draft.isHovered ? 0.05 : 0), lineWidth: 0.5).allowsHitTesting(false))
                .background(TelosTheme.primary.opacity(draft.isPressed ? 0.05 : 0), in: shape)
                .onHover { draft.isHovered = $0 }
        }
    }
}
struct MessageBubble: View {
    var text: String
    var body: some View {
        MessageText(text: text, markdown: false).font(.system(size: 13.5)).tracking(-0.135).lineSpacing(1)
            .foregroundStyle(TelosTheme.shade(0.15, 0.88)).multilineTextAlignment(.leading)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(TelosTheme.bubble, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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

/// Geometry callbacks run inside SwiftUI's layout. Writing state there starts another
/// transaction within the same update; if the value then flips back (a footer that
/// rewraps, a viewport squeezed by it), that update never finishes and the window stops
/// responding — seen during live resize. Such writes are applied on the next main-loop
/// turn instead, coalesced to the latest value.
@MainActor final class NextTurnWrite<Value> {
    private var pending: Value?
    func callAsFunction(_ value: Value, _ apply: @escaping (Value) -> Void) {
        let scheduled = pending != nil
        pending = value
        guard !scheduled else { return }
        DispatchQueue.main.async { [self] in
            guard let value = pending else { return }
            pending = nil
            apply(value)
        }
    }
}

/// True while the user drags a window edge. Decorative per-row effects step down for
/// those frames and return when the drag ends; the frame budget goes to text reflow.
@MainActor final class LiveResizeState: ObservableObject {
    static let shared = LiveResizeState()
    @Published private(set) var active = false
    private var observers: [NSObjectProtocol] = []
    func track(_ window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = true }
            },
            NotificationCenter.default.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.active = false }
            },
        ]
    }
}
private struct LiveResizingKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var isLiveResizing: Bool {
        get { self[LiveResizingKey.self] }
        set { self[LiveResizingKey.self] = newValue }
    }
}

private struct ScrollEdgeConfiguration {
    var height: CGFloat = 0
    var top: CGFloat = 0
    var bottom: CGFloat = 0
    var headerBlur = false
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
private struct ScrollDecorativeReplicaKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Blur layers only draw pixels. They must not create another native text
    /// selection overlay, which can feed lazy row measurements back into layout.
    var scrollDecorativeReplica: Bool {
        get { self[ScrollDecorativeReplicaKey.self] }
        set { self[ScrollDecorativeReplicaKey.self] = newValue }
    }
}

private struct ScrollTextSelection: ViewModifier {
    @Environment(\.scrollDecorativeReplica) private var decorativeReplica
    @ViewBuilder func body(content: Content) -> some View {
        if decorativeReplica { content.textSelection(.disabled) }
        else { content.textSelection(.enabled) }
    }
}

extension View {
    /// Keep selection on the real text, with drawing-only blurred replicas.
    func scrollTextSelection() -> some View { modifier(ScrollTextSelection()) }
}

private struct ProgressiveScrollBlur: ViewModifier {
    @Environment(\.scrollEdgeConfiguration) private var edge
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if !reduceTransparency && edge.height > 0 && edge.headerBlur {
            // SoftScrollEdges already fades this complete viewport over the
            // window glass. Per-row masks read changing lazy-row coordinates
            // and can feed them back into layout after panel hide/show.
            content
        } else if !reduceTransparency && edge.height > 0 {
            content.mask { edgeMask(inverted: true) }
        } else { content }
    }
    private func headerMask(level: Int) -> some View {
        GeometryReader { geometry in
            let y = geometry.frame(in: .scrollView(axis: .vertical)).minY
            let height = max(1, geometry.size.height)
            if !intersectsHeaderTransition(y: y, height: height) {
                // Outside either transition every sampled weight is constant.
                // Avoid building/sorting 100 gradient positions for normal rows.
                Rectangle().fill(.white.opacity(Double(headerWeight(level: level, position: y))))
            } else {
                // Include the viewport's transition positions even for a very long
                // paragraph. Sampling only the item's bounds would blur the whole
                // paragraph instead of the few points passing beneath the header.
                let positions = Array(Set(([CGFloat(0), height] + (0...48).map {
                    edge.top * CGFloat($0) / 48 - y
                } + (0...48).map {
                    edge.height - edge.bottom * CGFloat($0) / 48 - y
                }).map { min(height, max(0, $0)) })).sorted()
                LinearGradient(stops: positions.map { position in
                    .init(color: .white.opacity(Double(headerWeight(level: level, position: position + y))), location: position / height)
                }, startPoint: .top, endPoint: .bottom)
            }
        }
    }
    private func intersectsHeaderTransition(y: CGFloat, height: CGFloat) -> Bool {
        // The caller includes the soft copy's 16pt padding. Rows outside these
        // bands have no blurred pixels visible within the scroll viewport.
        (edge.top > 0 && y < edge.top && y + height > 0)
            || (edge.bottom > 0 && y < edge.height && y + height > edge.height - edge.bottom)
    }
    private func headerWeight(level: Int, position: CGFloat) -> CGFloat {
        let top = edge.top > 0 ? max(0, min(1, 1 - position / edge.top)) : 0
        let bottom = edge.bottom > 0 ? max(0, min(1, (position - edge.height + edge.bottom) / edge.bottom)) : 0
        let t = max(top, bottom)
        let first = Self.smoothstep(min(1, t * 2))
        let second = Self.smoothstep(max(0, t * 2 - 1))
        return level == 0 ? 1 - first : level == 1 ? first - second : second
    }
    private static func smoothstep(_ value: CGFloat) -> CGFloat { value * value * (3 - 2 * value) }
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

enum ScrollEdgeTreatment {
    case material
    /// Fade the rendered content into the window's existing glass, without
    /// adding a second material surface with its own rectangular bounds.
    case contentFade
    /// Content passes beneath the floating header. Only item drawing softens;
    /// the viewport fades transparently into the existing window glass.
    case underHeader
    /// The same transparent, progressively blurred underpass behind both the
    /// floating header and composer. Other scroll surfaces keep their own edges.
    case underControls
}

/// A gently curved transparency transition, with a slightly deeper center.
/// This paints alpha into a mask, never a color/material over the content.
private struct HeaderScrollFade: View {
    var opacity: CGFloat
    var preserveGlassBackdrop = false
    var body: some View {
        Canvas { context, size in
            let columns = max(1, min(192, Int(ceil(size.width))))
            let width = size.width / CGFloat(columns)
            // All columns use the same alpha ramp; only its depth changes.
            let gradient = Gradient(stops: (0...24).map { step -> Gradient.Stop in
                let t = CGFloat(step) / 24
                // The bottom mask is rotated. Keep contrast behind its
                // clear glass until the content nears the window edge.
                let progress = preserveGlassBackdrop ? (1 - t) * (1 - t) : t
                let eased = progress * progress * (3 - 2 * progress)
                let alpha = 1 - opacity * (preserveGlassBackdrop ? eased : 1 - eased)
                return .init(color: .black.opacity(Double(alpha)), location: t)
            })
            context.blendMode = .copy
            for index in 0..<columns {
                let x = (CGFloat(index) + 0.5) / CGFloat(columns)
                let centered = 2 * x - 1
                let depth = size.height * (1 - 0.16 * centered * centered)
                context.fill(Path(CGRect(x: CGFloat(index) * width, y: 0, width: width + 0.5, height: size.height)),
                             with: .linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: 0, y: depth)))
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
    let treatment: ScrollEdgeTreatment
    @State private var overflow = CGSize.zero
    @State private var viewportHeight: CGFloat = 0
    @State private var deferOverflow = NextTurnWrite<CGSize>()
    @State private var deferViewport = NextTurnWrite<CGFloat>()
    func body(content: Content) -> some View {
        // Fixed overlay bands need no scroll observer. In particular Chat owns
        // its geometry observation for follow/jump-to-latest; installing another
        // listener here would replace that observer on the same ScrollView.
        if alwaysTop && alwaysBottom {
            edges(content, topOpacity: 1, bottomOpacity: 1)
        } else if #available(macOS 15, *) {
            tracked(content)
                .onScrollGeometryChange(for: CGSize.self) { geometry in
                    // Once either fade reaches full opacity, further overflow
                    // changes do not need to invalidate the scroll subtree.
                    CGSize(width: min(18, max(0, geometry.contentOffset.y + geometry.contentInsets.top)),
                           height: min(18, max(0, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.contentOffset.y - geometry.containerSize.height)))
                } action: { _, value in deferOverflow(value) { if overflow != $0 { overflow = $0 } } }
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
            // Dark glass already supplies the backdrop blur. Rendering blurred
            // copies of each row here would add a white halo over the alpha fade.
            .environment(\.scrollEdgeConfiguration, edgeConfiguration(topOpacity: topOpacity, bottomOpacity: bottomOpacity))
            // Report only what the edge configuration reads, so a live resize does not
            // write this state, and run layout a second time, on every frame.
            .onGeometryChange(for: CGFloat.self) { proxy in
                PicoDiag.track("scrollEdges \(treatment) top\(Int(top))", "\(proxy.size.width)x\(proxy.size.height)")
                return relevantViewportHeight(proxy.size.height)
            } action: { value in deferViewport(value) { if viewportHeight != $0 { viewportHeight = $0 } } }
            .mask {
                if treatment == .underHeader || treatment == .underControls {
                    GeometryReader { geometry in
                        let height = max(1, geometry.size.height)
                        let topBand = min(max(0, top), height / 2)
                        let bottomBand = min(max(0, bottom), height / 2)
                        VStack(spacing: 0) {
                            HeaderScrollFade(opacity: topOpacity).frame(height: topBand)
                            Rectangle().fill(.black)
                            if treatment == .underControls {
                                HeaderScrollFade(opacity: bottomOpacity, preserveGlassBackdrop: true).rotationEffect(.degrees(180)).frame(height: bottomBand)
                            } else {
                            LinearGradient(stops: (0...16).map { index in
                                let t = CGFloat(index) / 16
                                let alpha = 1 - bottomOpacity * t * t * (3 - 2 * t)
                                return .init(color: .black.opacity(Double(alpha)), location: t)
                            }, startPoint: .top, endPoint: .bottom).frame(height: bottomBand)
                            }
                        }
                    }
                } else if treatment == .contentFade {
                    GeometryReader { geometry in
                        let height = max(1, geometry.size.height)
                        // Bound both fade bands when the window is resized. Their
                        // opacity follows actual overflow, so first/last rows stay
                        // fully visible at the beginning/end of the scroll.
                        let topBand = min(max(0, top), height / 2)
                        let bottomBand = min(max(0, bottom), height / 2)
                        LinearGradient(stops:
                            (0...16).map { index in
                                let t = CGFloat(index) / 16
                                let alpha = 1 - topOpacity * (1 - t * t * (3 - 2 * t))
                                return .init(color: .black.opacity(Double(alpha)), location: topBand * t / height)
                            } + (0...16).map { index in
                                let t = CGFloat(index) / 16
                                let alpha = 1 - bottomOpacity * (t * t * (3 - 2 * t))
                                return .init(color: .black.opacity(Double(alpha)), location: 1 - bottomBand * (1 - t) / height)
                            }, startPoint: .top, endPoint: .bottom)
                    }
                } else { Rectangle() }
            }
            .overlay(alignment: .top) {
                if treatment == .material { ScrollEdgeFade(whiteSurface: whiteSurface).frame(height: top).opacity(topOpacity) }
            }
            .overlay(alignment: .bottom) {
                if treatment == .material { ScrollEdgeFade(top: false, whiteSurface: whiteSurface).frame(height: bottom).opacity(bottomOpacity) }
            }
    }
    /// Only the material treatment's rows read the exact viewport height. The header
    /// treatments need just "visible" and whether the viewport is shorter than twice
    /// the fade band; content fades read none of it.
    private func relevantViewportHeight(_ height: CGFloat) -> CGFloat {
        switch treatment {
        case .material: return height
        case .contentFade: return height > 0 ? 1 : 0
        case .underHeader, .underControls: return min(height, 2 * max(0, top))
        }
    }
    private func edgeConfiguration(topOpacity: CGFloat, bottomOpacity: CGFloat) -> ScrollEdgeConfiguration {
        switch treatment {
        case .material:
            return ScrollEdgeConfiguration(height: viewportHeight, top: top * topOpacity, bottom: bottom * bottomOpacity)
        case .contentFade:
            return ScrollEdgeConfiguration()
        case .underHeader:
            return headerConfiguration
        case .underControls:
            // The input's native clear glass supplies its own optical blur.
            // Preblurring the same text here flattens it into an opaque haze.
            // Its bottom alpha fade remains in the viewport mask above.
            return headerConfiguration
        }
    }
    /// Rows only need the top band: with no bottom band, their masks never read the
    /// viewport height. Keeping it out of the environment means a live resize does
    /// not invalidate every row's effect on every frame.
    private var headerConfiguration: ScrollEdgeConfiguration {
        ScrollEdgeConfiguration(height: viewportHeight > 0 ? 1 : 0, top: min(max(0, top), max(0, viewportHeight) / 2),
                                bottom: 0, headerBlur: true)
    }
}
extension View {
    func softScrollEdges(top: CGFloat = 24, bottom: CGFloat = 28, alwaysTop: Bool = false, alwaysBottom: Bool = false, whiteSurface: Bool = false, treatment: ScrollEdgeTreatment = .material) -> some View {
        modifier(SoftScrollEdges(top: top, bottom: bottom, alwaysTop: alwaysTop, alwaysBottom: alwaysBottom, whiteSurface: whiteSurface, treatment: treatment))
    }
}

struct TaskComposer: View {
    @ObservedObject var draft: ComposerDraft
    @Environment(\.colorScheme) private var colorScheme
    var action: () -> Void
    private var expanded: Bool { !draft.files.isEmpty || draft.compactLayoutHeight > 22 }
    var body: some View {
        AttachmentInput(draft: draft, placeholder: "What would you like to do?", identifier: "newTaskField", action: action)
            .padding(.leading, expanded ? 12 : 44).padding(.trailing, expanded ? 12 : 48)
            .padding(.top, expanded ? 12 : 14).padding(.bottom, expanded ? 52 : 14)
            .frame(minHeight: 48)
            .background(ComposerHitArea(draft: draft))
            .background(colorScheme == .light ? TelosTheme.raised : .clear,
                        in: RoundedRectangle(cornerRadius: expanded ? 20 : 24))
            .modifier(PicoControlGlass(shape: RoundedRectangle(cornerRadius: expanded ? 20 : 24)))
            .overlay(RoundedRectangle(cornerRadius: expanded ? 20 : 24).stroke(draft.isFocused || draft.isHovered ? Color.black.opacity(0.05) : TelosTheme.primary.opacity(0.09), lineWidth: 0.5).allowsHitTesting(false))
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
