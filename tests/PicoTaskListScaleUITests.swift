import AppKit
import SwiftUI
import Vision

/// Exercise the real Tasks surface with private inert data. No model request,
/// global pointer event, installed-app operation or production save occurs.
@main struct PicoTaskListScaleUITests {
    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("pico-task-list-scale-" + UUID().uuidString)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/pico-task-list-scale-tests")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        setenv("TELOS_DATA_DIR", data.path, 1); setenv("TELOS_PREVIEW", "list", 1)
        defer {
            try? FileManager.default.removeItem(at: data)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let now = Date(), calendar = Calendar.current
        let store = TaskStore()
        precondition(store.dataDir.standardizedFileURL.path == data.standardizedFileURL.path)
        var todos = (0..<10_000).map { index in
            var task = Todo(title: "TODO \(String(format: "%05d", index))")
            task.status = "ready"; task.summary = "Task list scale fixture \(index)."
            task.created = now.addingTimeInterval(Double(-index * 60))
            return task
        }
        todos[9999].messages = [Message(role: "assistant", text: "Historical message search sentinel.")]
        todos[9998].artifacts = [Artifact(path: "historical-fixture-file.md", name: "historical-fixture-file.md")]
        var completed = (0..<10_000).map { index in
            var task = Todo(title: "DONE \(String(format: "%05d", index))")
            task.status = "completed"; task.summary = "Completed list scale fixture \(index)."
            task.created = now.addingTimeInterval(Double(-index * 90))
            // One very large Today section exposes an eager nested section.
            task.completedAt = index < 9000 ? now.addingTimeInterval(Double(-index) / 10)
                : calendar.date(byAdding: .day, value: -(1 + (index - 9000) / 250), to: now)
            return task
        }
        completed[9999].messages = [Message(role: "assistant", text: "Archived message search sentinel.")]
        store.tasks = todos + completed
        store.completed = false; store.selected = nil
        let allIDs = Set(store.tasks.map(\.id))
        let fixture = PicoTaskListScaleState(store: store)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let host = FirstMouseHostingView(rootView: PicoTaskListScaleFixture(state: fixture))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 777),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua); window.level = .floating
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle(_ seconds: Double = 0.4) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func wait(_ label: String, timeout: Double = 10, _ predicate: () -> Bool) {
            let start = Date(); var stable = 0
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                stable = predicate() ? stable + 1 : 0
                if stable >= 3 { return }
            } while Date().timeIntervalSince(start) < timeout
            fatalError("Timed out waiting for \(label); native \(nativePosition()); first measured task \(String(describing: actualTaskAnchor())); controller \(controller().diagnosticSnapshot)")
        }
        func transcript() -> NSScrollView {
            descendants(host).compactMap { $0 as? NSScrollView }.filter { $0.contentView.bounds.height > 200 }
                .max(by: { $0.bounds.width < $1.bounds.width })!
        }
        func controller() -> PicoChatScrollController {
            descendants(host).compactMap { ($0 as? PicoChatScrollProbeView)?.controller }.first!
        }
        func frames() -> [String: CGRect] {
            Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
        }
        func nativePosition() -> (offset: CGFloat, origin: CGFloat, viewport: CGFloat, maximum: CGFloat) {
            let scroll = transcript(), document = transcript().documentView!, clip = transcript().contentView.bounds
            let probe = descendants(host).compactMap { $0 as? PicoChatScrollProbeView }.first!
            let rect = probe.convert(probe.bounds, to: document)
            return (document.isFlipped ? clip.minY : document.bounds.maxY - clip.maxY,
                    document.isFlipped ? rect.minY : document.bounds.maxY - rect.maxY,
                    clip.height, max(0, document.bounds.height - scroll.contentView.bounds.height))
        }
        func actualTaskAnchor() -> PicoChatScrollController.Anchor? {
            let position = nativePosition(), top = position.offset - position.origin
            let visible = frames().filter { $0.key.hasPrefix("task:") && $0.value.maxY > top + 0.5 && $0.value.minY < top + position.viewport }
            guard let first = visible.min(by: { $0.value.minY < $1.value.minY }) else { return nil }
            return .init(id: first.key, offset: top - first.value.minY)
        }
        func requireAnchor(_ context: String, _ anchor: PicoChatScrollController.Anchor, clamp: Bool = false) {
            wait(context) {
                guard let frame = frames()[anchor.id] else { return false }
                let position = nativePosition()
                let expected = clamp && anchor.offset > 0 ? min(anchor.offset, max(0, frame.height - 1)) : anchor.offset
                return abs((position.offset - position.origin - frame.minY) - expected) <= 2
            }
            let frame = frames()[anchor.id]!, position = nativePosition()
            let actual = position.offset - position.origin - frame.minY
            let expected = clamp && anchor.offset > 0 ? min(anchor.offset, max(0, frame.height - 1)) : anchor.offset
            print("ANCHOR \(context): UUID \(anchor.id), actual \(actual), expected \(expected), frame \(frame)")
        }
        func requireLazy(_ context: String) {
            let realized = frames().filter { $0.key.hasPrefix("task:") }.count
            precondition(realized > 0 && realized < 60, "Task list must realize nearby rows, not its entire section: \(context), count \(realized)")
            precondition(store.tasks.count >= 19_999 && Set(store.tasks.map(\.id)) == allIDs)
            print("PASS \(context): \(realized) realized tasks / \(store.tasks.count) retained history")
        }
        func userScroll(to offset: CGFloat) {
            let scroll = transcript(), document = transcript().documentView!
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            let y = max(0, min(nativePosition().maximum, offset))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? y : document.bounds.maxY - scroll.contentView.bounds.height - y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            settle()
        }
        func pageAtBottom(_ context: String) {
            // Capture the old visible row at the actual user edge, immediately
            // before the production paging callback can evict any task rows.
            wait(context + " prior restore settled") { !controller().isRestoringReadingPosition }
            let owner = controller(), savedEdge = controller().onUserEdge
            var edgeAnchor: PicoChatScrollController.Anchor?
            owner.onUserEdge = { top, bottom in
                if bottom && edgeAnchor == nil { edgeAnchor = owner.prepareForChange() }
                savedEdge?(top, bottom)
            }
            defer { owner.onUserEdge = savedEdge }
            // A lazy stack can refine its height after the first native scroll.
            // A second real user gesture reaches that revised end if necessary.
            for _ in 0..<4 where edgeAnchor == nil {
                userScroll(to: nativePosition().maximum + 10)
            }
            guard let anchor = edgeAnchor else { fatalError("No user page edge reached: \(context), position \(nativePosition())") }
            print("PAGE \(context): preserving \(anchor)")
            wait(context + " preserves page-edge anchor") {
                guard let frame = frames()[anchor.id] else { return false }
                let position = nativePosition()
                let offset = position.offset - position.origin - frame.minY
                // The first measured lazy row can be lower in the viewport;
                // preserve that exact row's screen position, even after rows
                // above it finish registering their own geometry.
                return abs(offset - anchor.offset) <= 2
            }
            let anchoredFrame = frames()[anchor.id]!
            let anchoredPosition = nativePosition()
            let actualOffset = anchoredPosition.offset - anchoredPosition.origin - anchoredFrame.minY
            precondition(anchor.offset > -anchoredPosition.viewport && anchor.offset < anchoredFrame.height,
                         "The preserved task anchor must actually intersect the viewport")
            print("PAGE \(context): actual offset \(actualOffset), expected \(anchor.offset), frame \(anchoredFrame)")
        }
        func editorRect() -> CGRect {
            let editor = descendants(host).compactMap { $0 as? AttachmentTextView }.first!
            let viewport = editor.enclosingScrollView!
            let rect = viewport.convert(viewport.bounds, to: host)
            return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func pressCheckbox(in row: CGRect) {
            let scroll = transcript(), position = nativePosition()
            let nativePoint = NSPoint(x: row.minX + 23,
                                      y: row.midY - (position.offset - position.origin))
            let clip = scroll.contentView
            let point = clip.convert(NSPoint(x: clip.bounds.minX + nativePoint.x,
                                              y: clip.isFlipped ? clip.bounds.minY + nativePoint.y : clip.bounds.maxY - nativePoint.y), to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.02,
                                         windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
            print("CONTROL native task checkbox mouse pair delivered only to private window")
        }
        func capture(_ name: String) throws -> URL {
            window.displayIfNeeded(); settle(0.1)
            let path = output.appendingPathComponent(name + ".png")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0, "WindowServer capture required for task glass acceptance")
            return path
        }
        func requireText(_ path: URL, contains text: String) throws {
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(url: path, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            precondition(lines.contains { $0.localizedCaseInsensitiveContains(text) }, "Expected rendered \(text), got \(lines)")
        }

        settle(1)
        wait("Todo top") { abs(nativePosition().offset) <= 1 }
        requireLazy("Todo initial")
        let initialEditor = editorRect()
        try requireText(capture("todo-top"), contains: "TODO 00000")
        store.completed = true
        wait("Completed top") { abs(nativePosition().offset) <= 1 }
        precondition(editorRect() == initialEditor, "Switching Completed must not move the shared greeting or composer")
        requireLazy("Completed large Today section")
        try requireText(capture("completed-top"), contains: "Today")
        store.completed = false
        wait("Todo return top") { abs(nativePosition().offset) <= 1 }
        precondition(editorRect() == initialEditor)
        print("PASS Todo/Completed switch keeps the common header and native input fixed")
        userScroll(to: 100)
        wait("partially scrolled common chrome") { abs(nativePosition().offset - 100) <= 2 }
        let partialEditor = editorRect()
        store.completed = true
        wait("Completed preserves partial common chrome") { abs(nativePosition().offset - 100) <= 2 && editorRect() == partialEditor }
        store.completed = false
        wait("Todo preserves partial common chrome") { abs(nativePosition().offset - 100) <= 2 && editorRect() == partialEditor }
        fixture.query = "TODO 00000"
        wait("short search starts at top") { nativePosition().maximum <= 2 && abs(nativePosition().offset) <= 2 }
        fixture.query = ""
        wait("query return restores partial common chrome") { abs(nativePosition().offset - 100) <= 2 && editorRect() == partialEditor }
        NotificationCenter.default.post(name: .init("TelosTaskTop"), object: nil)
        wait("reset Todo chrome top") { abs(nativePosition().offset) <= 1 }
        store.completed = true
        wait("reset Completed chrome top") { abs(nativePosition().offset) <= 1 }
        store.completed = false
        wait("reset both scopes at top") { abs(nativePosition().offset) <= 1 }
        print("PASS 100pt shared header and native input stay fixed through Todo/Completed and query navigation")

        userScroll(to: 2400)
        wait("Todo reading anchor") { actualTaskAnchor() != nil }
        let todoAnchor = actualTaskAnchor()!
        requireLazy("Todo reading")
        store.completed = true
        wait("Completed independent top") { abs(nativePosition().offset) <= 1 }
        userScroll(to: 1800)
        wait("Completed reading anchor") { actualTaskAnchor() != nil }
        let completedAnchor = actualTaskAnchor()!
        store.completed = false
        requireAnchor("Todo reading restoration", todoAnchor)
        store.completed = true
        requireAnchor("Completed reading restoration", completedAnchor)
        print("PASS Todo and Completed retain independent stable task anchors")
        let completedEnd = nativePosition().maximum
        pageAtBottom("Completed same-section edge")
        wait("automatic next Completed page") { nativePosition().maximum > completedEnd + 2000 }
        controller().restore(completedAnchor)
        requireAnchor("Completed anchor after paging", completedAnchor)
        requireLazy("Completed same-section page")

        for size in [CGSize(width: 340, height: 528), CGSize(width: 560, height: 720), CGSize(width: 500, height: 777)] {
            let anchor = actualTaskAnchor()!
            window.setContentSize(size)
            requireAnchor("Completed resize \(size.width)", anchor, clamp: true)
            requireLazy("Completed resize \(Int(size.width))")
        }

        // Complete/reopen rows using the same Store actions as their checkboxes.
        store.completed = false
        requireAnchor("Todo before completing", todoAnchor)
        let beforeComplete = nativePosition().offset
        let victim = UUID(uuidString: todoAnchor.id.replacingOccurrences(of: "task:", with: ""))!
        store.complete(victim); settle()
        precondition(store.tasks.first { $0.id == victim }?.status == "completed")
        precondition(abs(nativePosition().offset - beforeComplete) < 150, "Removing one visible task must not jump to another page")
        requireLazy("complete visible task")
        store.reopen(victim); settle()
        precondition(store.tasks.first { $0.id == victim }?.status == "ready" && !store.completed)
        requireLazy("reopen task")
        let viewport = nativePosition()
        let top = viewport.offset - viewport.origin
        let clickRow = frames().filter { $0.key.hasPrefix("task:") && $0.value.minY - top >= 100 && $0.value.maxY - top <= viewport.viewport - 24 }
            .min { $0.value.minY < $1.value.minY }!
        let clickedID = UUID(uuidString: clickRow.key.replacingOccurrences(of: "task:", with: ""))!
        let clickedOffset = nativePosition().offset
        pressCheckbox(in: clickRow.value)
        wait("native checkbox completes the task") { store.tasks.first { $0.id == clickedID }?.status == "completed" }
        precondition(store.selected == nil, "Completing via checkbox must not open the task details")
        precondition(abs(nativePosition().offset - clickedOffset) < 150, "Native checkbox completion must preserve the reading page")
        store.reopen(clickedID); settle()
        precondition(store.tasks.first { $0.id == clickedID }?.status == "ready")
        print("PASS actual native checkbox invokes TaskBoard completion without opening details or leaving its page")

        // Reach several consecutive page edges. The document itself must stay
        // bounded as old rows are evicted, while native row realization stays lazy.
        let firstPageEnd = nativePosition().maximum
        pageAtBottom("Todo initial edge")
        wait("automatic next Todo page") { nativePosition().maximum > firstPageEnd + 2000 }
        for page in 0..<4 {
            pageAtBottom("Todo cap edge \(page + 1)")
            settle(0.2)
            precondition(nativePosition().maximum < 20_000, "Paging must not grow the whole task document forever")
            requireLazy("Todo page edge \(page + 1)")
        }
        print("PASS automatic successive task pages keep the document bounded and preserve page-edge task anchors")
        let pagedTodoAnchor = actualTaskAnchor()!
        let pagedTodoID = UUID(uuidString: pagedTodoAnchor.id.replacingOccurrences(of: "task:", with: ""))!
        precondition((todos.firstIndex { $0.id == pagedTodoID } ?? 0) > 80, "Scope restoration must cover an evicted first-page task")
        store.completed = true
        settle()
        // Visible shared chrome intentionally takes priority during a direct
        // Todo/Completed toggle. Test the independent later-page bookmark from
        // below that chrome, while the 100pt scenario above covers its priority.
        userScroll(to: 1200)
        wait("Completed below common chrome before paged Todo restoration") { nativePosition().offset > 800 }
        store.completed = false
        requireAnchor("Paged Todo scope restored from Completed reading", pagedTodoAnchor)
        print("PASS paged Todo retains its later-page anchor when returning from Completed reading")

        fixture.query = "Historical message search sentinel"
        wait("Full-history message search") { frames().keys.contains("task:" + todos[9999].id.uuidString) }
        try requireText(capture("historical-search"), contains: "TODO 09999")
        fixture.query = "historical-fixture-file.md"
        wait("Historical output search") { frames().keys.contains("task:" + todos[9998].id.uuidString) }
        precondition(store.tasks.count == 20_000 && Set(store.tasks.map(\.id)) == allIDs)
        fixture.query = ""
        requireAnchor("Paged Todo returns after clearing search", pagedTodoAnchor)
        store.completed = true
        settle()
        fixture.query = "Archived message search sentinel"
        wait("Completed full-history message search") { frames().keys.contains("task:" + completed[9999].id.uuidString) }
        try requireText(capture("archived-search"), contains: "DONE 09999")
        fixture.query = ""
        store.completed = false
        settle()
        NotificationCenter.default.post(name: .init("TelosTaskTop"), object: nil)
        wait("Explicit TaskTop") { abs(nativePosition().offset) <= 1 }
        try requireText(capture("todo-return-top"), contains: "TODO 00000")
        let regular = (FileManager.default.enumerator(at: data, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        precondition(regular.isEmpty, "Preview scale QA must never write task/meeting data")
        let editor = descendants(host).compactMap { $0 as? AttachmentTextView }.first!
        editor.draft?.setText("Local new task scale fixture")
        settle(0.2)
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        editor.keyDown(with: enter)
        wait("native new-task submit") { store.tasks.count == 20_001 && store.tasks.first?.messages.first?.text == "Local new task scale fixture" }
        let newID = store.tasks.first!.id
        wait("new task appears in bounded first page") { frames().keys.contains("task:" + newID.uuidString) }
        settle(0.7)
        try requireText(capture("local-new-task"), contains: "New task")
        precondition(store.tasks.first?.activeRunID == nil, "Preview submit must never launch an agent run")
        print("PASS native Return submits a new task into the bounded first page with its normal flight path")
        print("PASS actual TaskBoard:20k task history, bounded lazy Todo/Completed, independent scroll, completion/reopen, full-history message/file search, native header/input positions; screenshots \(output.path)")
    }
}

@MainActor private final class PicoTaskListScaleState: ObservableObject {
    let store: TaskStore
    @Published var query = ""
    init(store: TaskStore) { self.store = store }
}

private struct PicoTaskListScaleFixture: View {
    @ObservedObject var state: PicoTaskListScaleState
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    var body: some View {
        ZStack(alignment: .top) {
            TaskBoard(embedded: true, externalSearch: state.query, headerInset: 60, store: state.store)
            HStack { Text("Pico"); Spacer(); Text("Chat   Tasks   Events"); Spacer(); Text("Pico") }
                .font(.system(size: 13)).frame(height: 36).contentShape(Rectangle()).onTapGesture {}
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(stops: [.init(color: .black.opacity(0.99), location: 0), .init(color: .black.opacity(0.97), location: 0.8), .init(color: .black.opacity(0.4), location: 1)], startPoint: .top, endPoint: .bottom), in: shape)
            .modifier(PanelGlass(shape: shape)).clipShape(shape)
            .environment(\.colorScheme, .dark).foregroundStyle(.white)
    }
}
