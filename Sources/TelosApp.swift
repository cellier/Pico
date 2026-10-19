import SwiftUI
import Combine
import AppKit
import CoreText
import ApplicationServices

func serif(_ size: CGFloat) -> Font { .custom("InstrumentSerif-Regular", size: size) }
let lineColor = TelosTheme.shade(0.925, 0.27)

struct Brand: View {
    var size: CGFloat = 20
    var body: some View {
        if let url = Bundle.main.url(forResource: "status-icon", withExtension: "pdf"), let logo = NSImage(contentsOf: url) {
            Image(nsImage: logo).renderingMode(.template).resizable().interpolation(.high).foregroundStyle(TelosTheme.primary).frame(width: size, height: size).accessibilityLabel("Telos")
        }
    }
}
struct RootView: View {
    @ObservedObject var store: TaskStore
    @State private var stage = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let preview = ProcessInfo.processInfo.environment["TELOS_PREVIEW"]
    var body: some View {
        Group {
            if stage == 0 {
                HStack(spacing: 16) { Brand(size: 32); Text("Telos").font(serif(48)) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { TaskBoard(store: store) }
        }
        .background(TelosTheme.surface)
        
        .ignoresSafeArea()
        .onAppear {
            if let preview { stage = preview == "splash" ? 0 : preview == "tagline" ? 1 : 2; return }
            if UserDefaults.standard.bool(forKey: "hasLaunched") { stage = 2; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
                withAnimation(.easeInOut(duration: 0.25)) { stage = 2 }
                UserDefaults.standard.set(true, forKey: "hasLaunched")
            }
        }
        .allowsHitTesting(!store.showMacAccess)
        .accessibilityHidden(store.showMacAccess)
        .overlay {
            if store.showMacAccess {
                GeometryReader { geometry in
                    ZStack {
                        Color.black.opacity(0.35).contentShape(Rectangle())
                            .onTapGesture { store.showMacAccess = false }
                        MacAccessView(store: store, onClose: { store.showMacAccess = false })
                            .frame(width: max(0, geometry.size.width - 32), height: max(0, geometry.size.height - 40))
                            .background(TelosTheme.surface, in: RoundedRectangle(cornerRadius: 24))
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
                    }.frame(width: geometry.size.width, height: geometry.size.height)
                }.transition(.opacity)
            }
        }
        .buttonStyle(HoverButtonStyle(standard: true))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.showMacAccess)
        .alert("Telos", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}
struct TaskBoard: View {
    @ObservedObject private var calendar = CalendarStore.shared
    @ObservedObject var store: TaskStore
    @State private var tab: BoardTab = .tasks
    @StateObject private var draft = ComposerDraft()
    @State private var search = ""
    @State private var searching = false
    @State private var taskScrollInitialized = false
    @State private var manageFeeds = false
    @State private var composerRect: CGRect?
    @State private var flight: SendFlight?
    @State private var pendingFlight: (String, String, CGRect)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sheetDrag: CGFloat = 0
    var sheetAnimation: Animation? { reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.88) }
    private func windowResignEditor() { (NSApp.delegate as? AppDelegate)?.window.makeFirstResponder(nil) }
    func closeDetail() { withAnimation(sheetAnimation) { store.selected = nil; sheetDrag = 0 } }
    var detailOpen: Bool { store.selectedTask != nil && tab == .tasks }
    var body: some View {
        ZStack(alignment: .bottom) {
            panel.blur(radius: detailOpen ? 5.5 : 0).allowsHitTesting(!detailOpen).accessibilityHidden(detailOpen)
            if detailOpen {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { closeDetail() }
                    .accessibilityLabel("Close task details").accessibilityAddTraits(.isButton)
                    .transition(.opacity)
                ZStack(alignment: .top) {
                    detail
                    Capsule().fill(TelosTheme.shade(0.93, 0.23)).frame(width: 30, height: 5)
                        .frame(maxWidth: .infinity).frame(height: 28).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3)
                            .onChanged { sheetDrag = max(0, $0.translation.height) }
                            .onEnded { value in
                                if value.translation.height > 90 || value.predictedEndTranslation.height > 180 { closeDetail() }
                                withAnimation(sheetAnimation) { sheetDrag = 0 }
                            })
                        .accessibilityLabel("Dismiss task details").accessibilityAddTraits(.isButton)
                        .accessibilityAction { closeDetail() }
                }.frame(height: 664).background(TelosTheme.surface, in: UnevenRoundedRectangle(topLeadingRadius: 40, topTrailingRadius: 40))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 40, topTrailingRadius: 40))
                    .offset(y: sheetDrag).transition(.move(edge: .bottom)).zIndex(2)
            }
        }
            .clipped()
            .animation(sheetAnimation, value: detailOpen)
            .onChange(of: tab) { _, value in store.selected = nil; if value == .feed { store.feedCommand() } }
            .onChange(of: store.completed) { _, _ in store.selected = nil }
            .onChange(of: searching) { _, active in
                if !active { search = ""; windowResignEditor() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("TelosNewTask"))) { _ in tab = .tasks; store.completed = false }
            .onReceive(NotificationCenter.default.publisher(for: .init("TelosTaskTop"))) { _ in store.selected = nil }
            .onReceive(NotificationCenter.default.publisher(for: .init("TelosShowHome"))) { _ in
                tab = .tasks; store.completed = false; store.selected = nil
                store.showMacAccess = false; searching = false; search = ""; manageFeeds = false
            }
            .onExitCommand { if searching { searching = false; search = "" } else { store.selected = nil } }
            .onReceive(NotificationCenter.default.publisher(for: .init("TelosSearch"))) { _ in searching = true }
            .sheet(isPresented: $manageFeeds) { FeedRulesView(store: store, newFeed: newFeed) }
            .onAppear {
                let mode = ProcessInfo.processInfo.environment["TELOS_PREVIEW"]
                if mode == "feed" { tab = .feed }
                if mode == "search" { searching = true }
                if mode == "settings" || mode == "profile" { store.showMacAccess = true }
                if mode == "completed" { store.completed = true }
                if mode?.hasPrefix("calendar") == true { tab = .calendar }
                if mode == "input" { draft.setText("What can you do for me?") }
                if mode == "multiline" { draft.setText("What can you do for me? What can you do for me?\nhi What can you do for me?What can you do for me?\nWhat can you do for me? hi What can you do for\nWhat can you do for me? hi") }
            }
    }
    @ViewBuilder var detail: some View {
        if let todo = store.selectedTask {
            if let meetingID = todo.meetingID, let session = store.meetings[meetingID] {
                MeetingDetailView(store: store, session: session).id(meetingID)
            } else { TaskDetail(store: store, todo: todo).id(todo.id) }
        }
        else { TelosTheme.surface }
    }
    var panel: some View {
        ZStack(alignment: .top) {
            Group {
                if tab == .feed {
                    FeedList(store: store, query: activeSearch, newFeed: newFeed, topInset: 60)
                } else if tab == .calendar {
                    CalendarList(calendar: calendar, query: activeSearch, searching: false, search: $search)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: 0).id("taskTop")
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(HomeClock.text(context.date))
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(TelosTheme.primary)
                                            .frame(height: 24)
                                            .padding(.leading, 2)
                                            .accessibilityIdentifier("homeDateTime")
                                        Text(greeting(context.date)).font(serif(32))
                                            .frame(height: 36, alignment: .leading)
                                    }.progressiveScrollBlur()
                                }.padding(.horizontal, 26).padding(.top, 70).padding(.bottom, 20)
                                TaskComposer(draft: draft, action: submit)
                                    .trackRect("composer", in: "taskFlight").padding(.horizontal, 20).padding(.bottom, 16)
                                HStack(spacing: 0) {
                                    ForEach([false, true], id: \.self) { done in
                                        Button(done ? "Completed" : "Todo") { withAnimation(sheetAnimation) { store.completed = done } }
                                            .buttonStyle(HoverButtonStyle()).font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(store.completed == done ? TelosTheme.primary : TelosTheme.shade(0.5, 0.6))
                                            .padding(.horizontal, 6).frame(height: 24)
                                            .accessibilityAddTraits(store.completed == done ? .isSelected : [])
                                    }
                                }.padding(.horizontal, 20).padding(.bottom, 4).progressiveScrollBlur()
                                LazyVStack(spacing: 0) {
                                    if store.completed {
                                        TimelineView(.periodic(from: .now, by: 60)) { context in
                                            ForEach(CompletionSection.group(visibleTasks, now: context.date)) { section in
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(section.title).font(.system(size: 18, weight: .semibold)).progressiveScrollBlur()
                                                        .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 4)
                                                        .accessibilityAddTraits(.isHeader)
                                                    ForEach(section.tasks) { todo in taskRow(todo).id(todo.id) }
                                                }
                                            }
                                        }
                                    } else {
                                    ForEach(visibleTasks) { todo in
                                        taskRow(todo).id(todo.id).trackRect(todo.id.uuidString, in: "taskFlight")
                                            .opacity(flight?.target == todo.id.uuidString || pendingFlight?.0 == todo.id.uuidString ? 0 : 1)
                                    }
                                    }
                                    if visibleTasks.isEmpty && (!activeSearch.isEmpty || store.completed) {
                                        Text(activeSearch.isEmpty ? "All caught up" : "No results").font(.system(size: 14)).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity).padding(.top, 32)
                                    }
                                }.padding(.horizontal, 10).padding(.bottom, 18)
                            }
                        }.scrollIndicators(.hidden)
                        .softScrollEdges(top: 72, bottom: 40, alwaysTop: true)
                        .defaultScrollAnchor(ProcessInfo.processInfo.environment["TELOS_PREVIEW_SCROLL"] == "bottom" ? .bottom : .top)
                        .onAppear {
                            if !taskScrollInitialized {
                                taskScrollInitialized = true
                                if ProcessInfo.processInfo.environment["TELOS_PREVIEW_SCROLL"] != "bottom" { proxy.scrollTo("taskTop", anchor: .top) }
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .init("TelosTaskTop"))) { _ in
                            windowResignEditor()
                            withAnimation(sheetAnimation) { proxy.scrollTo("taskTop", anchor: .top) }
                        }
                        .onChange(of: store.tasks.first?.id) { _, id in if let id, pendingFlight != nil { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 36, height: 36)
                    Spacer(minLength: 0)
                    BoardSegments(selection: $tab).frame(width: 183, height: 36).inputGlass()
                    Spacer(minLength: 0)
                    GlassCircle(help: "Telos Settings", action: { store.showMacAccess = true; store.checkMacAccess() }) { Brand(size: 16) }
                        .contextMenu {
                            Button("New feed…", action: newFeed)
                            Button("Manage feeds…") { manageFeeds = true }
                            Button("Refresh feeds") { for feed in store.feeds where feed.enabled { store.refreshFeed(feed) } }
                        }
                }.opacity(searching ? 0 : 1).allowsHitTesting(!searching).accessibilityHidden(searching)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: searching)
                ExpandingSearchControl(active: $searching, text: $search)
                HStack {
                    Spacer()
                    GlassCircle(help: "Close search", action: { searching = false; search = "" }) {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .medium))
                    }
                }.opacity(searching ? 1 : 0).allowsHitTesting(searching).accessibilityHidden(!searching)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: searching)
            }.frame(height: 36).padding(.horizontal, 12).padding(.top, 12)

        }
        .background(TelosTheme.surface).coordinateSpace(name: "taskFlight")
        .onPreferenceChange(RectPreference.self) { values in
            // Store only the composer: lazy rows re-estimate their frames every pass, so storing them all never settles.
            if values["composer"] != composerRect { composerRect = values["composer"] }
            if let pending = pendingFlight, let destination = values[pending.0], destination.height > 0 {
                flight = SendFlight(text: pending.1, source: pending.2, destination: destination, target: pending.0)
                pendingFlight = nil
            }
        }
        .overlay { if let flight { FlightOverlay(flight: flight, finished: { self.flight = nil }).id(flight.id) } }
    }
    var activeSearch: String { searching ? search.trimmingCharacters(in: .whitespacesAndNewlines) : "" }
    var visibleTasks: [Todo] { activeSearch.isEmpty ? store.filtered : store.searchTasks(activeSearch) }
    func greeting(_ date: Date) -> String {
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil { return "Good Evening." }
        let hour = Calendar.current.component(.hour, from: date)
        return hour < 12 ? "Good Morning." : hour < 18 ? "Good Afternoon." : "Good Evening."
    }
    func taskRow(_ todo: Todo) -> some View {
        HStack(spacing: 12) {
            TaskCompletionToggle(completed: todo.status == "completed", running: todo.status == "running") { todo.status == "completed" ? store.reopen(todo.id) : store.complete(todo.id) }
            VStack(alignment: .leading, spacing: 2) {
                Text(todo.title).font(.system(size: 15)).tracking(-0.1).lineLimit(1)
                if let meetingID = todo.meetingID, let meeting = store.meetings[meetingID] {
                    TimelineView(.periodic(from: .now, by: 15)) { tick in
                        Text("\(todo.summary) · \(max(0, Int((meeting.endTime ?? tick.date).timeIntervalSince(meeting.startTime) / 60))) min")
                            .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else { Text(todo.summary).font(.system(size: 14)).tracking(-0.2).foregroundStyle(TelosTheme.shade(0.46, 0.64)).lineLimit(1) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 66)
            .background(store.selected == todo.id ? TelosTheme.shade(0.93, 0.23) : Color.clear, in: RoundedRectangle(cornerRadius: 24))
            .progressiveScrollBlur()
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .onTapGesture { store.selected = store.selected == todo.id ? nil : todo.id }
            .contextMenu {
                Button("Open task") { store.selected = todo.id }
                if ["running", "awaiting_approval"].contains(todo.status) { Button("Stop") { store.stop(todo.id) } }
                if ["error", "paused"].contains(todo.status) { Button(todo.status == "pending" ? "Start task" : "Retry") { store.retry(todo.id) } }
                if todo.status == "completed" && todo.meetingID == nil { Button("Reopen") { store.reopen(todo.id) } }
            }
    }
    func submit() {
        guard draft.hasContent else { return }
        let text = draft.text, source = composerRect
        search = ""; tab = .tasks
        guard let id = store.add(text, files: draft.files) else { return }; draft.clear()
        if !reduceMotion, text.utf16.count <= 2000, let source { pendingFlight = (id.uuidString, text, source) }
    }
    func newFeed() { manageFeeds = false; tab = .tasks; draft.setText("Create a feed for "); NotificationCenter.default.post(name: .init("TelosNewTask"), object: nil) }
}
struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tasks, messages, and feed", text: $text).textFieldStyle(.plain).focused($focused).accessibilityIdentifier("searchField")
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(HoverButtonStyle()).accessibilityLabel("Clear search") }
        }.font(.system(size: 13)).padding(.horizontal, 14).frame(height: 36).inputGlass().onAppear { focused = true }
    }
}
struct TaskCompletionToggle: View {
    let completed: Bool
    var running = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            Group {
                if completed || hovering {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Color.primary)
                } else if running {
                    TaskRunningRing()
                } else {
                    Circle().strokeBorder(TelosTheme.shade(0.71, 0.47), lineWidth: 1.2)
                }
            }.frame(width: 14, height: 14)
                .scaleEffect(hovering && !reduceMotion ? 1.12 : 1).frame(width: 14, height: 24)
                .contentShape(Rectangle().size(width: 22, height: 28))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: hovering)
            .accessibilityLabel(completed ? "Reopen task" : "Complete task")
            .accessibilityValue(running && !completed ? "In progress" : "")
    }
}
/// One 14-point checkbox border. The darker leading section travels along that same path.
struct TaskRunningRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if reduceMotion { TaskBorderStroke() }
        else { RotatingTaskRing() }
    }
}
private struct TaskBorderStroke: View {
    var body: some View {
        Circle().strokeBorder(AngularGradient(stops: [
            .init(color: TelosTheme.shade(0.71, 0.47), location: 0),
            .init(color: TelosTheme.shade(0.71, 0.47), location: 0.62),
            .init(color: TelosTheme.shade(0.60, 0.60), location: 0.76),
            .init(color: TelosTheme.shade(0.32, 0.90), location: 0.94),
            .init(color: TelosTheme.shade(0.71, 0.47), location: 1)
        ], center: .center), lineWidth: 1.2)
    }
}
private struct RotatingTaskRing: View {
    @State private var rotating = false
    var body: some View {
        TaskBorderStroke()
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { rotating = true } }
            .onDisappear { rotating = false }
    }
}
struct BlackButton: PrimitiveButtonStyle {
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 26, *) {
            Button(configuration).buttonStyle(.glassProminent).nativeHoverFeedback().buttonBorderShape(.capsule).tint(TelosTheme.shade(0, 0.35)).foregroundStyle(.white)
        } else { Button(configuration).buttonStyle(.borderedProminent).nativeHoverFeedback().tint(TelosTheme.shade(0, 0.35)).foregroundStyle(.white) }
    }
}
struct TaskDetail: View {
    @ObservedObject var store: TaskStore
    let todo: Todo
    @StateObject private var ask = ComposerDraft()
    @State private var footerHeight: CGFloat = 80
    @State private var composerRect: CGRect?
    @State private var flight: SendFlight?
    @State private var pendingFlight: (String, String, CGRect)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Message heights change while streaming and approvals append.
                        // Eager placement keeps scrollTo(bottom) from repeatedly
                        // re-estimating a lazy stack's variable-height predecessors.
                        VStack(alignment: .leading, spacing: 24) {
                            if let meetingID = todo.sourceMeetingID, let evidence = todo.sourceTranscriptEvidence {
                                VStack(alignment: .leading, spacing: 8) {
                                    Button("From meeting · " + meetingTimestamp(evidence.startTime)) {
                                        if let parent = store.tasks.first(where: { $0.meetingID == meetingID }) { store.completed = true; DispatchQueue.main.async { store.selected = parent.id } }
                                    }.buttonStyle(.bordered).nativeHoverFeedback()
                                    Text(evidence.text).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                                    if let date = todo.dueDate { Text("Due " + date).font(.system(size: 12)).foregroundStyle(.secondary) }
                                }
                            }
                            ForEach(todo.messages) { message in
                                messageView(message).id(message.id)
                                    .trackRect(message.id.uuidString, in: "messageFlight", when: pendingFlight?.0 == message.id.uuidString)
                                    .opacity(flight?.target == message.id.uuidString || pendingFlight?.0 == message.id.uuidString ? 0 : 1)
                            }
                            if let stream = store.streams[todo.id], !stream.isEmpty { MessageText(text: stream, markdown: false).font(.system(size: 14)) }
                            if todo.status == "running" && ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(todo.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                                    Spacer()
                                    Button { store.stop(todo.id) } label: { Image(systemName: "stop.circle") }.buttonStyle(HoverButtonStyle()).help("Stop task")
                                }
                            }
                            if ["error", "paused", "needs_input", "pending"].contains(todo.status) {
                                Text(todo.summary).font(.system(size: 14)).foregroundStyle(.secondary)
                                if todo.status != "needs_input" { Button(todo.status == "pending" ? "Start task" : "Retry") { store.retry(todo.id) } }
                            }
                            ForEach(todo.artifacts) { artifact in
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: artifact.path)) } label: { Label(artifact.name, systemImage: "doc.text").font(.system(size: 14)) }.buttonStyle(.bordered).nativeHoverFeedback()
                            }
                            Color.clear.frame(height: footerHeight + 16).id("bottom")
                        }.padding(.horizontal, 24).padding(.top, 36).frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.hidden)
                    .softScrollEdges(top: 56, bottom: footerHeight + 32, alwaysTop: false, alwaysBottom: true, whiteSurface: true)
                    .onChange(of: todo.messages.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                VStack(spacing: 0) {
                if let approval = todo.approval {
                    ScrollView { ApprovalCard(approval: approval, onDecision: { store.decide(todo.id, approve: $0) }, onStop: { store.stop(todo.id) }) }
                        .softScrollEdges(top: 16, bottom: 20).frame(maxHeight: min(380, geometry.size.height * 0.65)).padding(.horizontal, 16)
                }
                Composer(draft: ask, placeholder: "Add a comment", canSend: canSend, identifier: "askField", action: submit)
                    .trackRect("composer", in: "messageFlight").padding(.horizontal, 16).padding(.vertical, 16)
                }.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }.background(TelosTheme.surface).coordinateSpace(name: "messageFlight")
                .onPreferenceChange(RectPreference.self) { values in
                    // Store only the composer: lazy rows re-estimate their frames every pass, so storing them all never settles.
                    if values["composer"] != composerRect { composerRect = values["composer"] }
                    if let pending = pendingFlight, let dest = values[pending.0], dest.height > 0 {
                        let target = CGRect(x: max(24, dest.maxX-min(dest.width, 263)), y: min(dest.minY, geometry.size.height-100), width: min(dest.width, 263), height: dest.height)
                        flight = SendFlight(text: pending.1, source: pending.2, destination: target, target: pending.0); pendingFlight = nil
                    }
                }
                .overlay { if let flight { FlightOverlay(flight: flight, finished: { self.flight = nil }).id(flight.id) } }
        }
    }
    @ViewBuilder func messageView(_ message: Message) -> some View {
        if message.role == "user" {
            HStack { Spacer(minLength: 36); MessageBubble(text: message.text).frame(maxWidth: 300, alignment: .trailing) }
        } else if message.role == "confirmation" {
            Label(message.text, systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(.secondary)
        } else { MessageText(text: message.text).font(.system(size: 14)).lineSpacing(1).frame(maxWidth: .infinity, alignment: .leading) }
    }
    var canSend: Bool { ask.hasContent && !["running", "awaiting_approval"].contains(todo.status) }
    func submit() {
        guard canSend else { return }
        let text = ask.text, source = composerRect
        guard store.ask(todo.id, text: text, files: ask.files) else { return }; ask.clear()
        if !reduceMotion, text.utf16.count <= 2000, let source, let id = store.selectedTask?.messages.last?.id { pendingFlight = (id.uuidString, text, source) }
    }
}
struct ApprovalCard: View {
    let approval: MacApproval
    let onDecision: (Bool) -> Void
    let onStop: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "hand.raised")
                Text(approval.risk == "plan" ? "Approve work plan" : "Your confirmation").font(serif(24))
                Spacer()
                Button(action: onStop) { Image(systemName: "stop.circle") }.buttonStyle(HoverButtonStyle()).help("Stop task")
            }
            Text(approval.app).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(approval.reason).font(.system(size: 14)).textSelection(.enabled)
            if approval.risk == "script" {
                Text("This script can change apps or files. Confirm only the exact action described and shown below.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let path = approval.screenshotPath, let image = NSImage(contentsOfFile: path) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: path)) } label: {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 150)
                }.buttonStyle(HoverButtonStyle()).help("Open the reviewed app screenshot")
            }
            DisclosureGroup("Exact operation") {
                ScrollView { Text(approval.details).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.softScrollEdges(top: 12, bottom: 16).frame(maxHeight: 150)
            }.font(.system(size: 12))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let expired = context.date >= approval.expiresAt
                HStack(spacing: 16) {
                    Button(approval.risk == "plan" ? "Approve plan" : "Approve once") { onDecision(true) }.buttonStyle(BlackButton()).disabled(expired)
                    Button("Deny") { onDecision(false) }.buttonStyle(HoverButtonStyle())
                    Spacer()
                    Text(expired ? "Expired" : approval.risk == "plan" ? "Listed steps only" : "One action only").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }.padding(20).background(TelosTheme.shade(0.97, 0.17))
    }
}
struct MacAccessView: View {
    @AppStorage(TaskExecutionPolicy.preference) private var automaticExecution = true
    @AppStorage("TelosVoiceTypingEnabled") private var voiceTypingEnabled = true
    @AppStorage("TelosVoicePolish") private var voicePolish = true
    @AppStorage(DictationBailianAccount.preference) private var bailianDictation = DictationBailianAccount.saved.endpoint != nil
    @State private var dictationTester = BailianDictation()
    @State private var dictationTestMessage: String?
    @State private var dictationTestRunning = false
    @ObservedObject private var calendar = CalendarStore.shared
    @State private var showProfile = false
    @State private var apiKey = ""
    @State private var apiMessage: String?
    @State private var apiError = false
    @ObservedObject var store: TaskStore
    var onClose: () -> Void
    var body: some View {
        Group {
            if showProfile {
                ProfileView(store: store, onClose: { showProfile = false })
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Telos Settings").font(serif(28)); Spacer()
                        Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 14)).frame(width: 28, height: 28) }
                            .buttonStyle(HoverButtonStyle()).accessibilityLabel("Close settings")
                    }.padding(20)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
            if let notice = store.permissionResetNotice {
                Text(notice).font(.system(size: 13)).padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TelosTheme.shade(0.94, 0.20), in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("DeepSeek API Key").font(.system(size: 14, weight: .medium))
                SecureField("Enter your API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder).font(.system(size: 14))
                    .accessibilityIdentifier("deepseekAPIKey")
                    .onChange(of: apiKey) { _, _ in apiMessage = nil }
                HStack {
                    Text("Stored on this Mac only.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") {
                        do {
                            try ProviderSettings(directory: store.dataDir).save(apiKey: apiKey)
                            apiError = false
                            apiMessage = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? "API key removed." : "Saved. Applies to new requests; running tasks keep their current key."
                        } catch {
                            apiError = true; apiMessage = "Could not save. Check the key and local configuration."
                        }
                    }.buttonStyle(.bordered).nativeHoverFeedback()
                }
                if let apiMessage {
                    Text(apiMessage).font(.system(size: 12)).foregroundStyle(apiError ? Color.red : Color.secondary)
                }
            }
            Divider()
            Toggle("Automatic execution", isOn: $automaticExecution).font(.system(size: 14, weight: .medium))
            Text("Complete typed and spoken requests without approval clicks, including app actions, scripts and requested sends or changes. Ask only when essential information is missing. You can stop a task at any time. Changes apply to the next task or retry.").font(.system(size: 13)).foregroundStyle(.secondary)
            Text("macOS permissions, sign-in and identity verification may still need your confirmation. Background feeds only collect and organize information.").font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            Text("Telos uses macOS Harness to read and operate apps for your tasks. Relevant app text and requested screenshots are sent to DeepSeek for processing.").font(.system(size: 14))
            Text("Web search, opening websites, files and skills work without Mac control permissions.").font(.system(size: 13)).foregroundStyle(.secondary)
            MeetingSettingsView(manager: store.meetingManager)
            Divider()
            KeyDisplaySettingsView()
            Divider()
            Toggle("Voice typing · Hold left mouse", isOn: $voiceTypingEnabled).font(.system(size: 14, weight: .medium))
            Text("Hold still in an editable text field for 0.55 seconds. Speak after the tone, then release to insert. Dragging cancels; password fields are excluded. Automatic insertion does not appear in the keystroke display.").font(.system(size: 13)).foregroundStyle(.secondary)
            BailianSettingsView(settings: BailianSettings(directory: store.dataDir))
            Toggle("Bailian voice typing · Chinese + English", isOn: $bailianDictation)
            Text("Uses your existing Bailian voice account and Qwen Audio 3.1 ASR Flash for Chinese, English and mixed speech. Held recordings are sent to Bailian and billed by usage. If Bailian is unavailable, Telos automatically recognizes on this Mac without polishing. Turn off to always recognize locally.").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(DictationBailianAccount.saved.endpoint == nil ? "Save your Bailian key and workspace above to enable cloud recognition." : "Bailian region and workspace are configured. Test below to check key access and recognition.").font(.system(size: 12)).foregroundStyle(.secondary)
            Button(dictationTestRunning ? "Testing recognition…" : "Test Bailian recognition") {
                guard let sample = Bundle.main.url(forResource: "dictation-mixed-check", withExtension: "wav") else { return }
                dictationTestRunning = true; dictationTestMessage = nil
                dictationTester.transcribe(sample) { result in
                    dictationTestRunning = false
                    switch result {
                    case .success(let text): dictationTestMessage = text.isEmpty ? "No speech recognized." : text
                    case .failure(let error): dictationTestMessage = (error as NSError).code == URLError.userAuthenticationRequired.rawValue
                        ? "Bailian key unavailable. Save your Bailian API key above. Hold-to-talk will use local recognition until access is restored."
                        : "Bailian test failed (code: \((error as NSError).code)). Hold-to-talk will use local recognition."
                    }
                }
            }.disabled(dictationTestRunning)
            Text("Tests a fixed Chinese-English sample using your Bailian quota. No microphone recording or text insertion.").font(.system(size: 12)).foregroundStyle(.secondary)
            if let dictationTestMessage { Text(dictationTestMessage).font(.system(size: 13)).textSelection(.enabled) }
            Toggle("Polish local voice text with DeepSeek", isOn: $voicePolish).disabled(bailianDictation)
            Text("Local mode keeps audio on this Mac. Optional DeepSeek polishing sends only the transcript. Cloud recognition inserts its result directly, without another rewrite.").font(.system(size: 12)).foregroundStyle(.secondary)
            Button("Enable microphone & global typing") { (NSApp.delegate as? AppDelegate)?.dictation.requestPermissions() }
            Text("Screenshot · Option+A").font(.system(size: 14, weight: .medium))
            Text(store.screenshotShortcutStatus).font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Take Screenshot") { (NSApp.delegate as? AppDelegate)?.takeScreenshot() }
            Text("Screen Recording · Option+R").font(.system(size: 14, weight: .medium))
            Text(store.recordingShortcutStatus).font(.system(size: 13)).foregroundStyle(.secondary)
            Button("Record Screen") { (NSApp.delegate as? AppDelegate)?.recordScreen() }
            Button("Soul, Memory & Skills") { store.loadProfile(); showProfile = true }
            Text(store.macAccess).font(.system(size: 14)).textSelection(.enabled)
            Text("Grant missing system access here once. Telos keeps existing grants across updates and checks again when you return from System Settings.").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack {
                Button("Accessibility") {
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions(options) }
                    settings("Privacy_Accessibility")
                }
                Button("Screen Recording") {
                    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                    settings("Privacy_ScreenCapture")
                }
            }
            HStack {
                Text(calendar.authorized ? "Calendar: Connected" : "Calendar: Not connected").font(.system(size: 14))
                Spacer()
                Button(calendar.authorized ? "Permissions" : "Connect") {
                    if calendar.authorized || calendar.status == .denied || calendar.status == .restricted { calendar.openSettings() }
                    else { calendar.requestAccess() }
                }.disabled(calendar.requesting)
            }
            Button("Show Telos in Finder") { NSWorkspace.shared.selectFile(Bundle.main.bundlePath, inFileViewerRootedAtPath: "") }
            Text("If the system asks you to add an app, choose this Telos.app. After granting access, restart Telos and check again.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20).progressiveScrollBlur()
                    }.scrollIndicators(.hidden)
                    .softScrollEdges(top: 20, bottom: 24)
                    Divider()
                    HStack { Button("Check again") { store.checkMacAccess(); calendar.refresh() }; Spacer(); Button("Done", action: onClose).buttonStyle(BlackButton()) }.padding(20)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onExitCommand { if showProfile { showProfile = false } else { onClose() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                store.checkMacAccess(); calendar.refresh(); KeyDisplayController.shared.refresh()
            }
            .onAppear {
                do { apiKey = try ProviderSettings(directory: store.dataDir).apiKey() }
                catch { apiError = true; apiMessage = "Could not read the local API configuration." }
                if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "profile" { showProfile = true }
            }
    }
    func settings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}

struct ProfileView: View {
    @ObservedObject var store: TaskStore
    var onClose: () -> Void
    @State private var draft = ""
    @State private var tab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Your Telos").font(serif(30)); Spacer(); Button("Back", action: onClose) }
            Picker("Profile", selection: $tab) {
                Text("Soul").tag(0); Text("Memory").tag(1); Text("Skills").tag(2)
            }.pickerStyle(.segmented)
            if tab == 0 {
                Text("Personality and working style. Changes apply to your next ask; approvals always remain in effect.").font(.system(size: 13)).foregroundStyle(.secondary)
                TextEditor(text: $draft).font(.system(size: 13, design: .monospaced)).border(Color.gray.opacity(0.2))
                Button("Save Soul") { store.saveSoul(draft) }.buttonStyle(BlackButton())
            } else if tab == 1 {
                Text("Shared across tasks. Ask Telos to remember a preference; review or forget it here.").font(.system(size: 13)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if store.memoryNotes.isEmpty { Text("No memories yet.").foregroundStyle(.secondary) }
                        ForEach(store.memoryNotes) { note in
                            HStack(alignment: .top) {
                                Text(note.text).textSelection(.enabled); Spacer()
                                Button("Forget") { store.loadProfile(deleteMemory: note.id) }
                            }
                            Divider()
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.softScrollEdges(top: 16, bottom: 20)
            } else {
                Text("Hermes reads these skills when relevant. New skills require review; scripts and consequential actions still need approval.").font(.system(size: 13)).foregroundStyle(.secondary)
                ScrollView { VStack(alignment: .leading, spacing: 12) { ForEach(store.installedSkills, id: \.self) { name in Label(name, systemImage: "book.closed") } }.frame(maxWidth: .infinity, alignment: .leading) }.softScrollEdges(top: 16, bottom: 20)
                Button("Open Skills Folder") { NSWorkspace.shared.open(store.dataDir.appendingPathComponent("skills")) }
            }
            if let error = store.profileError { Text(error).foregroundStyle(.red).font(.system(size: 12)) }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { draft = store.soul }
            .onChange(of: store.soul) { _, value in draft = value }
    }
}

@MainActor final class PanelPresentation: ObservableObject {
    @Published var shown = false
    @Published var closing = false
    @Published var anchorX: CGFloat = 0.5
}
/// One continuous outline lets the native window shadow follow the arrow as well.
struct StatusPanelOutline: Shape {
    var anchorX: CGFloat
    func arrowTip(in rect: CGRect) -> CGPoint {
        // The rounded quadratic tip reaches y = 0.5 at its midpoint.
        CGPoint(x: min(rect.maxX - 3, max(rect.minX + 3, rect.minX + anchorX * rect.width)),
                y: rect.minY + 0.5)
    }
    func path(in rect: CGRect) -> Path {
        let tip = arrowTip(in: rect).x
        let half = min(14, tip - rect.minX, rect.maxX - tip)
        let top = rect.minY + 12
        let leftRadius = min(32, max(0, tip - rect.minX - half))
        let rightRadius = min(32, max(0, rect.maxX - tip - half))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + leftRadius, y: top))
        p.addLine(to: CGPoint(x: tip - half, y: top))
        p.addCurve(to: CGPoint(x: tip - half * 0.21, y: rect.minY + 2), control1: CGPoint(x: tip - half * 0.72, y: top), control2: CGPoint(x: tip - half * 0.43, y: rect.minY + 4))
        p.addQuadCurve(to: CGPoint(x: tip + half * 0.21, y: rect.minY + 2), control: CGPoint(x: tip, y: rect.minY - 1))
        p.addCurve(to: CGPoint(x: tip + half, y: top), control1: CGPoint(x: tip + half * 0.43, y: rect.minY + 4), control2: CGPoint(x: tip + half * 0.72, y: top))
        p.addLine(to: CGPoint(x: rect.maxX - rightRadius, y: top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + rightRadius), control: CGPoint(x: rect.maxX, y: top))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 32))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - 32, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + 32, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - 32), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: top + leftRadius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + leftRadius, y: top), control: CGPoint(x: rect.minX, y: top))
        p.closeSubpath()
        return p
    }
}
struct StatusPanelRoot: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var presentation: PanelPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var panelBackground: Color {
        let detailBrightness = store.selectedTask == nil ? 1.0 : 0.4
        return TelosTheme.shade(detailBrightness * (store.showMacAccess ? 0.65 : 1), 0.11 * detailBrightness * (store.showMacAccess ? 0.65 : 1))
    }
    var body: some View {
        RootView(store: store)
            .padding(.top, 12)
            .background(StatusPanelOutline(anchorX: presentation.anchorX).fill(panelBackground))
            .clipShape(StatusPanelOutline(anchorX: presentation.anchorX))

    }
}

/// Clip the native backing layer too: glass/backdrop sublayers can extend beyond a SwiftUI clip.
final class PanelHostingView: NSHostingView<StatusPanelRoot> {
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private let outlineMask = CAShapeLayer()
    private var hasPresented = false
    static let closeDuration: TimeInterval = 0.24
    /// Animate only compositing. SwiftUI scaleEffect changes AppKit scroll-view
    /// geometry and causes its clip view to compensate the visible origin.
    func animatePresentation(shown: Bool, anchor: CGPoint, reduced: Bool) {
        guard let layer else { return }
        // sublayerTransform is applied around the backing layer's anchorPoint,
        // not its bounds origin. Express the outline arrow tip relative to that pivot.
        let layerPoint = CGPoint(x: anchor.x, y: layer.isGeometryFlipped == isFlipped ? anchor.y : bounds.height - anchor.y)
        let anchor = CGPoint(x: layerPoint.x - layer.bounds.width * layer.anchorPoint.x,
                             y: layerPoint.y - layer.bounds.height * layer.anchorPoint.y)
        var collapsed = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        collapsed = CATransform3DScale(collapsed, shown ? 0.01 : 0, shown ? 0.01 : 0, 1)
        collapsed = CATransform3DTranslate(collapsed, -anchor.x, -anchor.y, 0)
        let target = shown || reduced ? CATransform3DIdentity : collapsed
        let from = hasPresented ? (layer.presentation()?.sublayerTransform ?? layer.sublayerTransform) : collapsed
        hasPresented = true
        layer.removeAnimation(forKey: "panelPresentation")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.sublayerTransform = target
        CATransaction.commit()
        guard !reduced else { return }
        // Interpolating an entire CATransform3D decomposes its zero-scale endpoint:
        // scale and translation then travel at different rates, moving the pivot.
        // Animate the scalar components together so T = pivot * (1 - scale)
        // remains true at every frame, including interrupted transitions.
        let components: [(String, CGFloat, CGFloat)] = [
            ("scale.x", from.m11, target.m11), ("scale.y", from.m22, target.m22),
            ("translation.x", from.m41, target.m41), ("translation.y", from.m42, target.m42)
        ]
        let duration = shown ? 0.5 : Self.closeDuration
        let group = CAAnimationGroup()
        group.duration = duration
        group.animations = components.map { key, start, end in
            let animation: CABasicAnimation
            if shown {
                let spring = CASpringAnimation(keyPath: "sublayerTransform." + key)
                spring.mass = 1; spring.stiffness = 380; spring.damping = 34
                animation = spring
            } else {
                animation = CABasicAnimation(keyPath: "sublayerTransform." + key)
            }
            animation.fromValue = start; animation.toValue = end
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            return animation
        }
        if !shown { group.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.85, 0.65) }
        layer.add(group, forKey: "panelPresentation")
    }
    private var lastMaskBounds = CGRect.null
    private var lastMaskAnchor: CGFloat = -1
    private var lastMaskFlipped = false
    private var lastMaskScale: CGFloat = 0
    override func layout() {
        super.layout()
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let anchor = rootView.presentation.anchorX
        guard lastMaskBounds != bounds || lastMaskAnchor != anchor || lastMaskFlipped != layer.isGeometryFlipped || lastMaskScale != scale else { return }
        lastMaskBounds = bounds; lastMaskAnchor = anchor; lastMaskFlipped = layer.isGeometryFlipped; lastMaskScale = scale
        let outline = StatusPanelOutline(anchorX: rootView.presentation.anchorX).path(in: bounds).cgPath
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outlineMask.frame = bounds
        if layer.isGeometryFlipped {
            outlineMask.path = outline
        } else {
            var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
            outlineMask.path = outline.copy(using: &flip)
        }
        outlineMask.fillColor = NSColor.white.cgColor
        outlineMask.contentsScale = window?.backingScaleFactor ?? 2
        layer.mask = outlineMask
        layer.masksToBounds = true
        CATransaction.commit()
        window?.invalidateShadow()
    }
}

final class TelosWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown { dismissInputFocus(at: event.locationInWindow) }
        super.sendEvent(event)
    }
    func dismissInputFocus(at point: NSPoint) {
        guard let editor = firstResponder as? NSTextView else { return }
        // Include the composer's padding, and the owning control of field editors.
        let surface = (editor as? DictationInputSurfaceProviding)?.dictationInputSurface
            ?? (editor.isFieldEditor ? editor.delegate as? NSView : nil)
            ?? editor
        guard surface.window === self else { return }
        let inside = surface.bounds.contains(surface.convert(point, from: nil))
            || editor.bounds.contains(editor.convert(point, from: nil))
        if !inside { makeFirstResponder(nil) }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var store: TaskStore!
    var statusItem: NSStatusItem!
    private let screenshots = ScreenshotController()
    private let recordings = ScreenRecordingController()
    private var screenshotEditor: ScreenshotEditor?
    let dictation = DictationController()
    private var companion: CompanionBridge?
    private var selectionTranslation: SelectionTranslationController?
    private var activityIndicator: StatusActivityIndicator?
    private var activitySubscriptions = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var deactivateObserver: NSObjectProtocol?
    var panelShown = false
    var transitionID = UUID()
    let presentation = PanelPresentation()
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "screenshot",
           let path = ProcessInfo.processInfo.environment["TELOS_SCREENSHOT_IMAGE"], let image = NSImage(contentsOfFile: path) {
            let editor = ScreenshotEditor(image: image); screenshotEditor = editor
            editor.closed = { NSApp.terminate(nil) }; editor.show(); return
        }
        if let fontURL = Bundle.main.url(forResource: "InstrumentSerif-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
        store = TaskStore()
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "translation" {
            selectionTranslation = SelectionTranslationController(store: store); selectionTranslation?.preview(); return
        }
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil {
            DispatchQueue.main.async { KeyDisplayController.shared.start() }
        }
        let view = PanelHostingView(rootView: StatusPanelRoot(store: store, presentation: presentation))
        window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 732), styleMask: [.borderless], backing: .buffered, defer: false)
        // Inherit the system appearance; the override is only for isolated previews.
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil,
           let mode = ProcessInfo.processInfo.environment["TELOS_PREVIEW_APPEARANCE"] {
            window.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        window.title = "Telos"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear; window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 400, height: 732)
        window.maxSize = window.minSize
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .none
        window.toolbarStyle = .unified

        window.contentView = view
        window.initialFirstResponder = view
        view.safeAreaRegions = []
        view.wantsLayer = true; view.layer?.masksToBounds = true
        window.isOpaque = false; window.hasShadow = true
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let url = Bundle.main.url(forResource: "status-icon", withExtension: "pdf"), let icon = NSImage(contentsOf: url) {
                icon.size = NSSize(width: 16, height: 16); icon.isTemplate = true; button.image = icon
            } else if let url = Bundle.main.url(forResource: "telos-logo", withExtension: "png"), let icon = NSImage(contentsOf: url) {
                icon.size = NSSize(width: 16, height: 16); icon.isTemplate = true; button.image = icon
            }
            button.toolTip = "Telos"; button.setAccessibilityLabel("Telos")
            (button.cell as? NSButtonCell)?.showsStateBy = [.changeBackgroundCellMask]
            button.target = self; button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            activityIndicator = StatusActivityIndicator(button: button)
            store.$tasks.map(StatusActivityIndicator.runningCount).removeDuplicates()
                .sink { [weak self] count in
                    self?.activityIndicator?.update(count: count, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                }.store(in: &activitySubscriptions)
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                .receive(on: RunLoop.main).sink { [weak self] _ in
                    guard let self else { return }
                    self.activityIndicator?.update(count: StatusActivityIndicator.runningCount(self.store.tasks), reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                }.store(in: &activitySubscriptions)

        }
        CalendarStore.shared.$events.combineLatest(CalendarStore.shared.$now)
            .receive(on: RunLoop.main).sink { [weak self] _, _ in self?.updateStatusEvent() }
            .store(in: &activitySubscriptions)
        // Other apps can add menu items or change the active display without a calendar update.
        Timer.publish(every: 2, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.updateStatusEvent() }.store(in: &activitySubscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.updateStatusEvent() }
            .store(in: &activitySubscriptions)
        if ProcessInfo.processInfo.environment["TELOS_SNAPSHOT"] != nil {
            let frame = panelFrame(); window.setFrame(frame, display: false)
            presentation.anchorX = ((statusButtonFrame?.midX ?? frame.midX) - frame.minX) / frame.width
            if let x = ProcessInfo.processInfo.environment["TELOS_PREVIEW_ANCHOR"].flatMap(Double.init) { presentation.anchorX = x }
            presentation.shown = true
        }
        else if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil { showPanel() }
        makeMenu()
        #if TELOS_DIAGNOSTICS
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil, let output = ProcessInfo.processInfo.environment["TELOS_MEETING_DIAGNOSTICS"] {
            Task { await PicoMeetingDiagnostics.run(output: URL(fileURLWithPath: output)) }
        }
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil, let output = ProcessInfo.processInfo.environment["TELOS_AUDIO_ROUTE_DIAGNOSTICS"] {
            Task { await PicoAudioRouteDiagnostics.run(output: URL(fileURLWithPath: output)) }
        }
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil, let output = ProcessInfo.processInfo.environment["TELOS_RECORDING_DIAGNOSTICS"] {
            Task { await ScreenRecordingDiagnostics.run(output: URL(fileURLWithPath: output)) }
        }
        #endif
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "pico-meeting" { store.meetingManager.pico.show() }
        #if TELOS_DIAGNOSTICS
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "recording", let output = ProcessInfo.processInfo.environment["TELOS_RECORDING_SNAPSHOTS"] {
            Task { await ScreenRecordingDiagnostics.snapshots(recordings, output: URL(fileURLWithPath: output)) }
        }
        #endif
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == "recording", ProcessInfo.processInfo.environment["TELOS_RECORDING_SNAPSHOTS"] == nil { recordings.start() }
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil,
           ProcessInfo.processInfo.environment["TELOS_SNAPSHOT"] == nil {
            dictation.start()
            companion = CompanionBridge(store:store,transcribe:{ [weak self] url, reply in self?.dictation.transcribeCompanion(url,reply:reply) },cancel:{ [weak self] in self?.dictation.cancelCompanion() },show:{ [weak self] id in self?.store.selected=id; self?.showPanel() })
            companion?.showMeeting = { [weak self] in self?.store.meetingManager.pico.show() }
            store.meetingManager.start()
            selectionTranslation = SelectionTranslationController(store: store)
            selectionTranslation?.start()
            screenshots.captured = { [weak self] image in
                guard let self else { return }
                self.screenshotEditor?.close()
                let editor = ScreenshotEditor(image: image)
                self.screenshotEditor = editor
                editor.closed = { [weak self] in self?.screenshotEditor = nil }
                editor.show()
            }
            screenshots.prepare = { [weak self] in self?.stopOutsideDismissal() }
            screenshots.finished = { [weak self] in
                guard let self, self.panelShown else { return }
                self.startOutsideDismissal()
            }
            screenshots.failed = { [weak self] message in self?.store.error = message; self?.showPanel() }
            if screenshots.register() != noErr {
                store.screenshotShortcutStatus = "Option+A is unavailable. Another app may be using it. Change that app's shortcut and restart Telos; Take Screenshot is still available in the menu."
            }
            // Recording hides the panel so it is neither captured nor dismissed by the selection overlay.
            recordings.prepare = { [weak self] in self?.hidePanel() }
            recordings.failed = { [weak self] message in self?.store.error = message; self?.showPanel() }
            if recordings.register() != noErr {
                store.recordingShortcutStatus = "Option+R is unavailable. Another app may be using it. Record Screen is still available in the menu."
            }
        }
        // App updates retain existing permissions. macOS requests any required
        // authorization through the normal feature-specific permission flow.
        if let path = ProcessInfo.processInfo.environment["TELOS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }
    private func updateStatusEvent() {
        guard let indicator = activityIndicator, let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        let calendar = CalendarStore.shared
        let event = CalendarSchedule.menuText(CalendarSchedule.next(calendar.events, now: calendar.now), now: calendar.now)
        let itemFrame = statusItemFrame
        let available = itemFrame == nil ? 0 : StatusActivityIndicator.availableWidth(screenFrame: screen.frame,
            topRightArea: screen.auxiliaryTopRightArea, itemFrame: itemFrame)
        let width = indicator.setEvent(event, availableWidth: available)
        if statusItem.length != width { statusItem.length = width }
        indicator.layout(width: width)
        if panelShown {
            let frame = panelFrame()
            if window.frame != frame { window.setFrame(frame, display: true) }
            presentation.anchorX = ((statusButtonFrame?.midX ?? frame.midX) - frame.minX) / frame.width
        }
    }
    private var statusItemFrame: NSRect? {
        guard let button = statusItem.button, let owner = button.window, owner.frame.width > 0 else { return nil }
        return owner.convertToScreen(button.convert(button.bounds, to: nil))
    }
    var statusButtonFrame: NSRect? {
        guard let button = statusItem.button, let owner = button.window, owner.frame.width > 0 else { return nil }
        let icon = activityIndicator?.iconFrame ?? button.bounds
        return owner.convertToScreen(button.convert(NSRect(x: icon.minX, y: button.bounds.minY, width: icon.width, height: button.bounds.height), to: nil))
    }
    var panelAnimationAnchor: NSPoint {
        guard let view = window.contentView else { return .zero }
        let tip = StatusPanelOutline(anchorX: presentation.anchorX).arrowTip(in: view.bounds)
        return NSPoint(x: tip.x, y: view.isFlipped ? tip.y : view.bounds.maxY - (tip.y - view.bounds.minY))
    }
    func panelFrame() -> NSRect {
        let anchor = statusButtonFrame
        let screen = statusItem.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let safe = screen.visibleFrame
        return NSRect(x: min(max((anchor?.midX ?? safe.midX) - 200, safe.minX + 8), safe.maxX - 408),
                      y: min(anchor?.minY ?? safe.maxY, safe.maxY) - 734, width: 400, height: 732)
    }
    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            let screenshot = menu.addItem(withTitle: "Take Screenshot — ⌥A", action: #selector(takeScreenshot), keyEquivalent: "")
            screenshot.target = self
            let recording = menu.addItem(withTitle: "Record Screen — ⌥R", action: #selector(recordScreen), keyEquivalent: "")
            recording.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit Telos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
            syncStatusHighlight()
            return
        }
        panelShown ? hidePanel() : showPanel()
    }
    private func syncStatusHighlight() {
        func apply() {
            statusItem.button?.state = panelShown ? .on : .off
            statusItem.button?.highlight(panelShown)
        }
        apply()
        // NSStatusBarButton clears its tracking highlight after mouseUp/action.
        // Restore the current panel state once that tracking cycle has finished.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusItem.button?.state = self.panelShown ? .on : .off
            self.statusItem.button?.highlight(self.panelShown)
        }
    }
    @objc func openSettings() { showPanel(); store.showMacAccess = true; store.checkMacAccess() }
    func showPanel() {
        guard !panelShown else { window.makeKeyAndOrderFront(nil); return }
        panelShown = true; let token = UUID(); transitionID = token
        syncStatusHighlight()
        presentation.closing = false
        window.ignoresMouseEvents = false
        startOutsideDismissal()
        let target = panelFrame()
        presentation.anchorX = min(1, max(0, ((statusButtonFrame?.midX ?? target.midX) - target.minX) / target.width))
        window.contentView?.needsLayout = true
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(target, display: false)
        window.alphaValue = reduced ? 1 : 0
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelShown, self.transitionID == token else { return }
            self.window.makeKey()
            self.presentation.shown = true
            (self.window.contentView as? PanelHostingView)?.animatePresentation(shown: true, anchor: self.panelAnimationAnchor, reduced: reduced)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduced ? 0 : 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(target, display: true); window.animator().alphaValue = 1
        }
    }
    @objc func hidePanel() {
        guard panelShown else { return }
        stopOutsideDismissal()
        window.makeFirstResponder(nil)
        panelShown = false; let token = UUID(); transitionID = token
        syncStatusHighlight()
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Keep the panel opaque and its frame fixed; the content collapses into the arrow.
        presentation.closing = true
        window.ignoresMouseEvents = true
        presentation.shown = false
        (window.contentView as? PanelHostingView)?.animatePresentation(shown: false, anchor: panelAnimationAnchor, reduced: reduced)
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduced ? 0 : PanelHostingView.closeDuration)) { [weak self] in
            guard let self, self.transitionID == token, !self.panelShown else { return }
            self.window.orderOut(nil)
            self.window.ignoresMouseEvents = false
        }
    }

    private func startOutsideDismissal() {
        stopOutsideDismissal()
        if ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil && ProcessInfo.processInfo.environment["TELOS_PREVIEW_PIN"] == "1" { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.dismissFromOutside()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            // Keep the status button's own toggle, sheets, menus and file picker functional.
            if event.window == self.window || event.window == self.statusItem.button?.window { return event }
            if let eventWindow = event.window, eventWindow.isVisible { return event }
            self.dismissFromOutside()
            return event
        }
        deactivateObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissFromOutside() }
        }
    }
    private func dismissFromOutside() {
        guard !screenshots.isSelecting, !recordings.isSelecting else { return }
        // A native file chooser owns a separate window; do not hide its composer underneath it.
        guard !NSApp.windows.contains(where: { $0 is NSSavePanel && $0.isVisible }) else { return }
        hidePanel()
    }
    private func stopOutsideDismissal() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let deactivateObserver { NotificationCenter.default.removeObserver(deactivateObserver) }
        outsideClickMonitor = nil; localClickMonitor = nil; deactivateObserver = nil
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The isolated screenshot preview has no main panel or status item.
        guard window != nil else { return false }
        showPanel(); return false
    }
    func makeMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let app = NSMenu(); appItem.submenu = app
        app.addItem(withTitle: "About Telos", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator()); app.addItem(withTitle: "Quit Telos", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); main.addItem(appItem)
        let fileItem = NSMenuItem(); let file = NSMenu(title: "File"); fileItem.submenu = file
        let new = NSMenuItem(title: "New Task", action: #selector(newTask), keyEquivalent: "n"); new.target = self; file.addItem(new)
        let close = file.addItem(withTitle: "Hide Telos", action: #selector(hidePanel), keyEquivalent: "w"); close.target = self; main.addItem(fileItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        for (name, action, key) in [("Undo", Selector(("undo:")), "z"), ("Cut", #selector(NSText.cut(_:)), "x"), ("Copy", #selector(NSText.copy(_:)), "c"), ("Paste", #selector(NSText.paste(_:)), "v"), ("Select All", #selector(NSText.selectAll(_:)), "a")] { edit.addItem(withTitle: name, action: action, keyEquivalent: key) }
        let search = NSMenuItem(title: "Search", action: #selector(searchTasks), keyEquivalent: "f"); search.target = self; edit.addItem(search)
        main.addItem(editItem); NSApp.mainMenu = main
    }
    @objc func takeScreenshot() { screenshots.start() }
    @objc func recordScreen() { recordings.start() }
    @objc func searchTasks() { NotificationCenter.default.post(name: .init("TelosSearch"), object: nil) }
    @objc func newTask() { showPanel(); NotificationCenter.default.post(name: .init("TelosNewTask"), object: nil) }
    private var finishingMeetingsOnQuit = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil, ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil else { return .terminateNow }
        guard !finishingMeetingsOnQuit else { return .terminateLater }
        finishingMeetingsOnQuit = true
        Task { await recordings.finishBeforeQuit(); await store.meetingManager.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { screenshots.finished = {}; stopOutsideDismissal(); screenshots.stop(); recordings.shutdown(); dictation.stop(); selectionTranslation?.stop(); KeyDisplayController.shared.stop(); screenshotEditor?.cancelWork(); store?.stopAll() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#if !TELOS_TEST
@main struct TelosMain {
    @MainActor static func main() {
        // Bundled Python must not write bytecode into the signed app.
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
        _ = delegate
    }
}
#endif
