import SwiftUI
import AppKit

enum PicoTab: String, CaseIterable { case chat = "Chat", tasks = "Tasks", events = "Events" }

/// Retain each tab's native editors and scroll position without reflowing hidden
/// tabs on every live-resize frame. Only the visible tab gets the new viewport.
struct PicoRetainedTabLayout: Layout {
    var activeIndex: Int
    struct Cache {
        var placedSizes: [CGSize?]
    }
    func makeCache(subviews: Subviews) -> Cache {
        Cache(placedSizes: Array(repeating: nil, count: subviews.count))
    }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Layout is a value: selecting a different tab must not throw away the
        // viewport sizes retained for its still-mounted siblings.
        if cache.placedSizes.count != subviews.count { cache = makeCache(subviews: subviews) }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        if let width = proposal.width, width.isFinite,
           let height = proposal.height, height.isFinite {
            return CGSize(width: max(0, width), height: max(0, height))
        }
        // Intrinsic-size queries only measure the active tab. The actual window
        // always proposes a bounded viewport and takes the path above.
        let ideal = subviews.isEmpty ? CGSize.zero : subviews[min(max(0, activeIndex), subviews.count - 1)].sizeThatFits(proposal)
        return CGSize(width: finite(proposal.width) ?? finite(ideal.width) ?? 0,
                      height: finite(proposal.height) ?? finite(ideal.height) ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        PicoDiag.track("tabLayout", "\(Int(bounds.width))x\(Int(bounds.height)) active=\(activeIndex)")
        updateCache(&cache, subviews: subviews)
        for index in subviews.indices {
            let size: CGSize
            if index == activeIndex || cache.placedSizes[index] == nil {
                size = bounds.size
                if size.width > 0 && size.height > 0 { cache.placedSizes[index] = size }
            } else {
                size = cache.placedSizes[index]!
            }
            subviews[index].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
    private func finite(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }
}

/// The window shell shares the translation window's native glass and exact Figma gradient.
struct PicoAppView: View {
    @ObservedObject var store: TaskStore
    @StateObject private var chat: PicoChatStore
    @State private var tab: PicoTab = .chat
    @State private var searching = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @Namespace private var tabSelection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    private var detailOpen: Bool { tab == .tasks && store.selectedTask != nil }
    init(store: TaskStore) {
        self.store = store
        _chat = StateObject(wrappedValue: store.chat)
    }
    var body: some View {
        ZStack(alignment: .top) {
          ZStack(alignment: .top) {
            PicoRetainedTabLayout(activeIndex: PicoTab.allCases.firstIndex(of: tab) ?? 0) {
                PicoChatView(chat: chat, query: searching ? query : "", headerInset: 60)
                    .opacity(tab == .chat ? 1 : 0).allowsHitTesting(tab == .chat).accessibilityHidden(tab != .chat)
                TaskBoard(embedded: true, externalSearch: searching ? query : "", headerInset: 60, store: store)
                    .opacity(tab == .tasks ? 1 : 0).allowsHitTesting(tab == .tasks).accessibilityHidden(tab != .tasks)
                CalendarList(calendar: CalendarStore.shared, query: searching ? query : "", searching: false, search: $query, topInset: 12, edgeTreatment: .contentFade, headerInset: 60, contentHorizontalInset: 18)
                    .opacity(tab == .events ? 1 : 0).allowsHitTesting(tab == .events).accessibilityHidden(tab != .events)
            }
            // Hidden pages retain their last viewport during live resize. Adopt
            // the current width before revealing one, without inheriting the
            // header's selection spring. Other content animations stay intact.
            .transaction(value: tab) { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(16)
            // The complete title area owns window dragging, including its top
            // margin and the transparent gap below the controls. Keep padding
            // inside the gesture so none of those regions falls through to chat.
            header.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 24)
                .modifier(WindowDrag())
          }
          .blur(radius: detailOpen ? PicoTaskDetailMetrics.backdropBlur : 0)
          .animation(PicoTaskDetailMetrics.animation(reduceMotion: reduceMotion), value: detailOpen)
          .allowsHitTesting(!detailOpen).accessibilityHidden(detailOpen)
          PicoTaskDetailPresentation(store: store, isPresented: detailOpen).zIndex(2)
        }
        .background(LinearGradient(stops: [
            .init(color: TelosTheme.panelTop, location: 0),
            .init(color: TelosTheme.panelMiddle, location: 0.8),
            .init(color: TelosTheme.panelBottom, location: 1)
        ], startPoint: .top, endPoint: .bottom), in: shape)
        .modifier(PanelGlass(shape: shape))
        .clipShape(shape)
        .foregroundStyle(TelosTheme.primary)
        .onChange(of: detailOpen) { _, open in
            if open { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("TelosNewTask"))) { _ in tab = .tasks }
        .onReceive(NotificationCenter.default.publisher(for: .init("TelosSearch"))) { _ in searching = true; searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .init("PicoShowTasks"))) { _ in
            searching = false; query = ""; searchFocused = false; tab = .tasks
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("PicoShowChat"))) { _ in
            searching = false; query = ""; searchFocused = false; tab = .chat
            chat.showLatest()
        }
        .onChange(of: chat.isRunning) { _, running in
            NotificationCenter.default.post(name: .init("PicoChatActivity"), object: running)
        }
        .onChange(of: searching) { _, active in
            if !active { query = ""; searchFocused = false; (NSApp.delegate as? AppDelegate)?.window.makeFirstResponder(nil) }
        }
        .onExitCommand {
            if detailOpen { withAnimation(PicoTaskDetailMetrics.animation(reduceMotion: reduceMotion)) { store.selected = nil } }
            else if searching { searching = false }
            else { (NSApp.delegate as? AppDelegate)?.hidePanel() }
        }
        .onAppear {
            store.proactivity.attach(chat: chat)
            // A cold-start companion request can precede notification subscriptions.
            if store.selectedTask != nil { tab = .tasks }
            let mode = ProcessInfo.processInfo.environment["TELOS_PREVIEW"] ?? ""
            if ["list", "input", "multiline", "completed", "detail", "approval", "meeting", "meeting-live"].contains(mode) { tab = .tasks }
            if mode.hasPrefix("calendar") || mode == "events" { tab = .events }
            if mode == "settings" { store.showMacAccess = true }
            if mode == "search" { searching = true }
        }
    }
    /// Below this width the search and settings buttons step aside so the tabs fit.
    private static let compactHeaderWidth: CGFloat = 260
    private var header: some View {
        // A fixed-height reader: measuring the header writes no state.
        GeometryReader { geometry in
            headerContent(compact: geometry.size.width < Self.compactHeaderWidth && !searching)
        }.frame(height: 36)
    }
    private func headerContent(compact: Bool) -> some View {
        ZStack(alignment: .leading) {
          if !searching {
           GlassGroup(spacing: 6) {
            HStack(spacing: 0) {
                if !compact { Color.clear.frame(width: 36, height: 36) }
                Spacer(minLength: compact ? 0 : 8)
                HStack(spacing: 2) {
                    ForEach(PicoTab.allCases, id: \.self) { value in
                        Button {
                            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) { tab = value }
                        } label: {
                            Text(value.rawValue).foregroundColor(TelosTheme.primary).font(.system(size: 13, weight: value == tab ? .medium : .regular))
                                .padding(.horizontal, 8).frame(height: 26)
                                .background {
                                    if value == tab {
                                        Capsule()
                                            .fill(LinearGradient(colors: [TelosTheme.selectedTabTop, TelosTheme.selectedTabBottom], startPoint: .top, endPoint: .bottom))
                                            .overlay { Capsule().stroke(TelosTheme.selectedTabBorder, lineWidth: 0.5) }
                                            .shadow(color: TelosTheme.selectedTabShadow, radius: 3, y: 1)
                                            .matchedGeometryEffect(id: "selectedTab", in: tabSelection)
                                    }
                                }
                        }.buttonStyle(HoverButtonStyle(hoverScale: 1)).accessibilityAddTraits(value == tab ? .isSelected : [])
                    }
                }.padding(.horizontal, 5).frame(height: 36)
                    .modifier(PicoHeaderGlass(shape: Capsule()))
                Spacer(minLength: compact ? 0 : 8)
                if !compact {
                Button { store.showMacAccess = true; store.checkMacAccess() } label: {
                    PicoAvatarView(size: 26, state: chat.isRunning ? "thinking" : "idle").frame(width: 26, height: 26).frame(width: 36, height: 36)
                        .contentShape(Circle())
                        .overlay(alignment: .bottom) {
                            Text("Pico").foregroundColor(TelosTheme.primary).font(.system(size: 8, weight: .medium)).padding(.horizontal, 5.5).frame(height: 16)
                                .modifier(PicoHeaderGlass(shape: Capsule())).offset(y: 2)
                        }
                }.buttonStyle(.plain).modifier(PicoHeaderGlass(shape: Circle(), interactive: true))
                    .help("Pico Settings").accessibilityLabel("Pico Settings")
                }
            }
           }.transition(.opacity).allowsHitTesting(!searching).accessibilityHidden(searching)
          }
            if searching {
                HStack(spacing: 8) {
                    Color.clear.frame(width: 36)
                    TextField("Search", text: $query).textFieldStyle(.plain).font(.system(size: 13)).focused($searchFocused)
                    Button { searching = false } label: { Image(systemName: "xmark").font(.system(size: 13)).frame(width: 36, height: 36) }
                        .buttonStyle(HoverButtonStyle()).accessibilityLabel("Close search")
                }.frame(height: 36).modifier(PicoHeaderGlass(shape: Capsule()))
                    .allowsHitTesting(searching).accessibilityHidden(!searching)
                    .transition(.scale(scale: 0.1, anchor: .leading).combined(with: .opacity))
            }
            if !compact {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82)) { searching.toggle() }
                if searching { searchFocused = true }
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .regular))
                    .frame(width: 36, height: 36).contentShape(Circle())
            }.buttonStyle(.plain)
                .modifier(PicoHeaderGlass(shape: Circle(), interactive: true, enabled: !searching))
                .help("Search").accessibilityLabel("Search")
                .zIndex(1)
            }
        }.frame(height: 36)
    }
}

struct PicoGlassButton: View {
    let symbol: String
    var size: CGFloat = 36
    var pointSize: CGFloat = 14
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: pointSize, weight: .regular)).frame(width: size, height: size).contentShape(Circle()) }
            .buttonStyle(.plain).modifier(GlassSurface(shape: Circle(), interactive: true))
            .help(help).accessibilityLabel(help)
    }
}

@MainActor private final class PicoChatRowCache: ObservableObject {
    private var revision: Int?
    private var query = ""
    private var messageCount = -1
    private var cached: [PicoChatTimelineRowDescriptor] = []
    func rows(chat: PicoChatStore, query: String) -> [PicoChatTimelineRowDescriptor] {
        if revision != chat.windowRevision || (!query.isEmpty && messageCount != chat.totalMessageCount) || self.query != query {
            revision = chat.windowRevision; messageCount = chat.totalMessageCount; self.query = query
            cached = PicoChatTimelineRows.build(messages: query.isEmpty ? chat.messages : chat.searchMessages(query),
                                                precedingMessage: query.isEmpty ? chat.precedingVisibleMessage : nil)
        }
        return cached
    }
}

@MainActor private final class PicoChatRowFrameCache {
    var frame: CGRect?
}

/// A lazy row may reappear at the exact same content rectangle. SwiftUI then
/// need not emit another geometry change, so re-register its last measurement.
private struct PicoChatRowGeometry: ViewModifier {
    let id: String
    let timeline: PicoChatScrollController
    @State private var cache = PicoChatRowFrameCache()
    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { proxy in
                let frame = proxy.frame(in: .named("picoChatTimeline"))
                PicoDiag.track("chatRow " + id.prefix(8) + id.suffix(3), "\(Int(frame.minY)),\(Int(frame.width))x\(Int(frame.height))")
                return frame
            } action: { frame in
                cache.frame = frame
                timeline.record(id: id, frame: frame)
            }
            .onAppear { if let frame = cache.frame { timeline.record(id: id, frame: frame) } }
            .onDisappear { timeline.remove(id: id) }
    }
}

struct PicoChatView: View {
    @ObservedObject var chat: PicoChatStore
    var query = ""
    var headerInset: CGFloat = 0
    @StateObject private var draft = ComposerDraft()
    @StateObject private var timeline = PicoChatScrollController()
    @StateObject private var rowCache = PicoChatRowCache()
    @StateObject private var liveRows = PicoChatLiveTimelineRowsCache()
    @StateObject private var rowWindow = PicoChatRowWindow()
    @State private var nearBottom = true
    @State private var footerHeight: CGFloat = 56
    @State private var deferFooter = NextTurnWrite<CGFloat>()
    @State private var streamID = UUID()
    @State private var navigationQuery: String?
    private struct LatestJumpContext {
        let rows: [PicoChatTimelineRowDescriptor]
        let anchor: PicoChatScrollController.Anchor?
    }
    @State private var latestJumpContext: LatestJumpContext?
    @State private var latestJumpInProgress = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLiveResizing) private var liveResizing
    private var showsLiveTurn: Bool { query.isEmpty && !chat.hasLaterMessages }
    private var showJump: Bool {
        query.isEmpty && (chat.hasLaterMessages || rowWindow.hasLater || !nearBottom) &&
        (!chat.messages.isEmpty || !chat.stream.isEmpty || !chat.pendingArtifacts.isEmpty)
    }
    private var allRows: [PicoChatTimelineRowDescriptor] {
        let history = rowCache.rows(chat: chat, query: query)
        guard showsLiveTurn && (!chat.stream.isEmpty || !chat.pendingArtifacts.isEmpty) else { return history }
        return history + liveRows.build(text: chat.stream, ownerMessageID: chat.responseMessageID ?? streamID,
                                        artifacts: chat.pendingArtifacts)
    }
    private var displayRows: [PicoChatTimelineRowDescriptor] {
        let current = rowWindow.rows(all: allRows, scope: query.isEmpty ? "history" : "search:" + query,
                                     followsLatest: query.isEmpty && ((latestJumpContext != nil && latestJumpInProgress) || timeline.followingLatest))
        guard query.isEmpty, let context = latestJumpContext else { return current }
        let ids = Set(current.map(\.id))
        // A far jump joins only the visible old context and the latest page.
        // Both ends scroll as real rows without realizing intervening history.
        return context.rows.filter { !ids.contains($0.id) } + current
    }
    var body: some View {
        // Reconcile the data window before reading its navigation flags below.
        let rows = displayRows
        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    // The row window already bounds the mounted history. Use
                    // measured heights: lazy estimates can oscillate against
                    // native text selection after a small panel is reopened.
                    VStack(alignment: .leading, spacing: 0) {
                        if rowWindow.hasEarlier || (query.isEmpty && chat.hasEarlierMessages) {
                            PicoHistoryLoading(label: "Load earlier messages", action: loadEarlier)
                        }
                        if query.isEmpty && !chat.unassignedArtifacts.isEmpty {
                            DisclosureGroup("Earlier files") { artifactLinks(chat.unassignedArtifacts) }
                                .font(.system(size: 12)).padding(.horizontal, 12).progressiveScrollBlur()
                        }
                        ForEach(rows) { row in
                            PicoChatTimelineRow(row: row,
                                openAttachment: { NSWorkspace.shared.open(chat.attachmentURL($0)) },
                                openArtifact: { NSWorkspace.shared.open(chat.artifactURL($0)) },
                                artifactsFolderURL: chat.workspace)
                                .id(row.id)
                                .modifier(PicoChatRowGeometry(id: row.id, timeline: timeline))
                        }
                        if showsLiveTurn && chat.isRunning && chat.stream.isEmpty {
                            PicoTypingIndicator().progressiveScrollBlur()
                        }
                        if showsLiveTurn, let error = chat.error {
                            HStack(alignment: .top) {
                                Text(error).font(.system(size: 12)).foregroundStyle(.secondary).scrollTextSelection()
                                Button("Retry") { chat.retry() }.buttonStyle(HoverButtonStyle())
                            }.padding(.horizontal, 12).padding(.bottom, 8).progressiveScrollBlur()
                        }
                        if rowWindow.hasLater || (query.isEmpty && chat.hasLaterMessages) {
                            PicoHistoryLoading(label: "Load later messages", action: loadLater).padding(.top, 8)
                        }
                        // The scroll view continues beneath the floating glass.
                        // Only the final reserve keeps its last line readable.
                        Color.clear.frame(height: chat.approval == nil ? footerHeight + 8 : 6)
                            .id("picoLatest")
                            .modifier(PicoChatRowGeometry(id: "picoLatest", timeline: timeline))
                    }
                    .scrollTargetLayout()
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8 + headerInset)
                    .coordinateSpace(name: "picoChatTimeline")
                    .background(PicoChatScrollProbe(controller: timeline))
                }
                .scrollIndicators(.hidden)
                .modifier(PicoChatScrollAnchor(liveResizing: liveResizing))
                .onChange(of: chat.hasLaterMessages) { _, _ in updateTailConstraint() }
                .onChange(of: rowWindow.hasLater) { _, _ in updateTailConstraint() }
                .onChange(of: rowWindow.revision) { _, _ in timeline.contentChanged() }
                .onChange(of: chat.windowRevision) { _, _ in timeline.contentChanged() }
                .onChange(of: chat.stream) { _, _ in timeline.contentChanged() }
                .onChange(of: chat.pendingArtifacts.count) { _, _ in timeline.contentChanged() }
                .onChange(of: footerHeight) { _, _ in timeline.contentChanged() }
                .onChange(of: query) { _, value in
                    resumeContinuousHistory()
                    configureTimeline(proxy: proxy)
                    timeline.navigate(scope: value.isEmpty ? "history" : "search:" + value)
                    navigationQuery = value
                    updateTailConstraint()
                    if value.isEmpty { chat.setFollowsLatest(timeline.followingLatest) }
                }
                .softScrollEdges(top: headerInset > 0 ? headerInset + 12 : 0,
                                 bottom: chat.approval == nil ? footerHeight + 16 : 16,
                                 alwaysTop: true, alwaysBottom: true,
                                 treatment: chat.approval == nil ? .underControls : .underHeader)
                .padding(.bottom, chat.approval == nil ? 0 : footerHeight)
                VStack(spacing: 0) {
                    if let approval = chat.approval {
                        ApprovalCard(approval: approval, onDecision: { chat.decide(approve: $0) }, onStop: { chat.stop() })
                            .frame(maxHeight: 180)
                    }
                    composer.padding(.top, 16)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    PicoDiag.track("chatFooter", "\(proxy.size.width)x\(proxy.size.height)")
                    return proxy.size.height
                } action: { height in
                    deferFooter(height) { if abs($0 - footerHeight) > 0.5 { footerHeight = $0 } }
                }
                if showJump {
                    Button(action: showLatest) {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
                            .frame(width: 31, height: 22)
                    }.buttonStyle(HoverButtonStyle()).modifier(PicoControlGlass(shape: Capsule(), interactive: true))
                        .disabled(latestJumpInProgress)
                        .padding(.bottom, max(48, footerHeight - 8))
                        .transition(.scale(scale: 0.2).combined(with: .opacity))
                        .accessibilityLabel("Jump to latest message").help("Jump to latest message")
                }
            }
            .onAppear {
                configureTimeline(proxy: proxy)
                timeline.navigate(scope: query.isEmpty ? "history" : "search:" + query)
                navigationQuery = query
                updateTailConstraint()
                timeline.contentChanged()
            }
        }
    }
    private func configureTimeline(proxy: ScrollViewProxy) {
        timeline.configure { id, anchor in proxy.scrollTo(id, anchor: anchor) }
        // Edge callbacks can arrive from a row's geometry action; apply them next turn.
        timeline.onEdges = { bottom, _ in
            DispatchQueue.main.async {
                guard bottom != nearBottom else { return }
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72)) { nearBottom = bottom }
            }
        }
        timeline.onFollowingChanged = { following in
            if query.isEmpty { chat.setFollowsLatest(following && !rowWindow.hasLater) }
        }
        timeline.onLatestAnimationFinished = finishLatestJump
        timeline.onLatestAnimationCancelled = {
            latestJumpInProgress = false
            rowWindow.cancelLatestJump()
            // Keep a cancelled bridge visible until normal navigation restores
            // its real page. Removing its visible rows would cause another jump.
        }
        timeline.onUserEdge = { top, bottom in DispatchQueue.main.async {
            guard latestJumpContext == nil, !latestJumpInProgress else { return }
            if top && (rowWindow.hasEarlier || (query.isEmpty && chat.hasEarlierMessages)) { loadEarlier() }
            else if bottom && (rowWindow.hasLater || (query.isEmpty && chat.hasLaterMessages)) { loadLater() }
        } }
    }
    private func updateTailConstraint() {
        // Data-window flags can change before query's onChange saves the old
        // scope. Apply them only after that navigation has completed.
        guard navigationQuery == query else { return }
        timeline.canFollowLatest = query.isEmpty && !chat.hasLaterMessages && !rowWindow.hasLater
    }
    private func loadEarlier() {
        resumeContinuousHistory()
        timeline.canFollowLatest = false
        let anchor = timeline.prepareForChange()
        if !rowWindow.hasEarlier && query.isEmpty && chat.hasEarlierMessages {
            chat.loadEarlier()
            _ = displayRows
        }
        rowWindow.loadEarlier()
        updateTailConstraint()
        timeline.restore(anchor)
    }
    private func loadLater() {
        resumeContinuousHistory()
        timeline.canFollowLatest = false
        let anchor = timeline.prepareForChange()
        if !rowWindow.hasLater && query.isEmpty && chat.hasLaterMessages {
            chat.loadLater()
            _ = displayRows
        }
        rowWindow.loadLater()
        updateTailConstraint()
        timeline.restore(anchor)
    }
    private func showLatest() {
        guard !latestJumpInProgress else { return }
        if reduceMotion {
            latestJumpContext = nil
            chat.showLatest(); rowWindow.finishLatestJump()
            timeline.canFollowLatest = true; timeline.followLatest()
            return
        }
        let current = displayRows
        let anchor = timeline.prepareForChange()
        let needsBridge = latestJumpContext != nil || chat.hasLaterMessages || rowWindow.hasLater
        if needsBridge {
            // Preserve the old prefix as well as the visible rows: removing it
            // before the first animation frame rebases the native viewport.
            // At most the existing240 rows plus the latest80 are retained.
            let index = anchor.flatMap { saved in current.firstIndex { $0.id == saved.id } } ?? 0
            let lower = current.count <= 240 ? 0 : max(0, min(index - 8, current.count - 240))
            latestJumpContext = LatestJumpContext(rows: Array(current[lower..<min(current.count, lower + 240)]), anchor: anchor)
            if chat.hasLaterMessages { chat.showLatest() }
            // Reconcile the new message page before selecting its final rows.
            // A long latest message may have thousands of chunks of its own.
            _ = displayRows
            rowWindow.showLatest()
        }
        rowWindow.beginLatestJump()
        latestJumpInProgress = true
        timeline.canFollowLatest = true
        timeline.followLatest(animated: true, preserving: needsBridge ? anchor : nil)
        if !timeline.isAnimatingLatest { finishLatestJump() }
    }
    private func finishLatestJump() {
        guard latestJumpInProgress else { return }
        latestJumpInProgress = false
        latestJumpContext = nil
        rowWindow.finishLatestJump()
        updateTailConstraint()
        timeline.contentChanged()
    }
    private func resumeContinuousHistory() {
        guard let context = latestJumpContext else {
            guard latestJumpInProgress else { return }
            timeline.cancelLatestJump()
            rowWindow.cancelLatestJump()
            latestJumpInProgress = false
            return
        }
        let anchor = timeline.cancelLatestJump() ?? context.anchor
        let candidates = context.rows + PicoChatTimelineRows.build(messages: chat.messages, precedingMessage: chat.precedingVisibleMessage)
        if let anchor, let row = candidates.first(where: { $0.id == anchor.id }) {
            chat.showMessage(containing: row.ownerMessageID)
            rowWindow.focus(on: anchor.id,
                            all: PicoChatTimelineRows.build(messages: chat.messages, precedingMessage: chat.precedingVisibleMessage),
                            scope: "history")
        }
        latestJumpContext = nil; latestJumpInProgress = false
        rowWindow.cancelLatestJump()
        timeline.restore(anchor)
    }
    @ViewBuilder private func artifactLinks(_ artifacts: [Artifact]) -> some View {
        PicoArtifactList(artifacts: artifacts, folderURL: chat.workspace,
                         openArtifact: { NSWorkspace.shared.open(chat.artifactURL($0)) })
            .padding(.horizontal, 12)
    }
    private var composer: some View {
        Composer(draft: draft, placeholder: "Message", canSend: true,
                 identifier: "picoChatField", isRunning: chat.isRunning,
                 stopAction: chat.stop, action: submit)
    }
    private func submit() {
        guard draft.hasContent, !draft.isComposing else { return }
        resumeContinuousHistory()
        if chat.send(draft.text, files: draft.files) {
            draft.clear(); rowWindow.showLatest(); timeline.canFollowLatest = true; timeline.followLatest()
            PicoSounds.messageSent()
        }
    }
}


/// Native positioning only supplies the initial offset and short-history alignment.
/// A lazy stack also changes its height after appearance, tab and settings updates,
/// not just during resize. Native size-change pinning can continually move the
/// viewport while those estimates settle and never return to the event loop.
/// PicoChatScrollController owns later tail maintenance, one main-loop turn later.
private struct PicoChatScrollAnchor: ViewModifier {
    let liveResizing: Bool
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .alignment)
                .defaultScrollAnchor(nil, for: .sizeChanges)
        } else {
            content.defaultScrollAnchor(liveResizing ? nil : .bottom)
        }
    }
}

/// Keep native editors above a full-strength clear-glass backing surface.
/// Putting the editor inside the material can flatten the scrolling backdrop.
struct PicoControlGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    func body(content: Content) -> some View {
        content.background {
            Color.clear.modifier(GlassSurface(shape: shape, interactive: interactive))
        }
    }
}

