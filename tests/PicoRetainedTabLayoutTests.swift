import AppKit
import SwiftUI

/// Resize a real hosting window while three native text editors stay mounted.
/// Hidden native frames, drafts, selection and scroll origins must remain intact.
@main struct PicoRetainedTabLayoutTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        setvbuf(stdout, nil, _IONBF, 0)
        let model = RetainedTabFixtureModel()
        let host = NSHostingView(rootView: RetainedTabFixture(model: model))
        host.sizingOptions = []; host.safeAreaRegions = []
        let initial = CGSize(width: 360, height: 480)
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 60, y: 60), size: initial),
                              styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
        func requireSize(_ index: Int, _ expected: CGSize, _ context: String) {
            let actual = model.probes[index].view!.frame.size
            precondition(abs(actual.width - expected.width) < 0.5 && abs(actual.height - expected.height) < 0.5,
                         "Tab \(index) frame changed unexpectedly during \(context): \(actual), expected \(expected)")
        }
        func resize(_ size: CGSize) { window.setContentSize(size); settle() }
        func select(_ index: Int, viewport: CGSize, context: String) {
            let probe = model.probes[index]
            let firstChange = probe.frameSizes.count
            // Match the actual header action: this transaction formerly animated
            // the incoming cached native width (360→620 overshot to 621.88pt).
            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { model.activeIndex = index }
            for frame in 0..<80 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                requireSize(index, viewport, "\(context), visible frame \(frame)")
            }
            let changes = probe.frameSizes.dropFirst(firstChange)
            precondition(changes.allSatisfy { abs($0.width - viewport.width) < 0.5 && abs($0.height - viewport.height) < 0.5 },
                         "Incoming tab animated through intermediate dimensions or overshoot: \(context), \(Array(changes))")
            precondition(changes.count <= 1, "Incoming tab must adopt the current viewport only once: \(context)")
            print("PASS: \(context) stays \(Int(viewport.width))×\(Int(viewport.height)) for 80 visible frames; no intermediate native frame or spring overshoot")
        }
        settle()
        for index in model.probes.indices { requireSize(index, initial, "initial placement") }
        let identities = model.probes.map { ObjectIdentifier($0.view!) }
        let drafts = model.probes.enumerated().map { index, probe in
            let text = "Unsent \(index): 中文 mixed English draft.\n" + String(repeating: "Retained native editor content.\n", count: 90)
            probe.view!.editor.string = text
            probe.view!.editor.setSelectedRange(NSRange(location: 7, length: 3))
            probe.view!.contentView.scroll(to: NSPoint(x: 0, y: 300 + index * 20))
            probe.view!.reflectScrolledClipView(probe.view!.contentView)
            return text
        }
        settle()
        let scrollOrigins = model.probes.map { $0.view!.contentView.bounds.origin.y }
        let hiddenResizeCounts = model.probes.map(\.distinctResizeCount)
        for step in 0..<12 {
            let size = CGSize(width: 380 + step * 20, height: 500 + step * 8)
            resize(size)
            requireSize(0, size, "Chat resize \(step)")
            requireSize(1, initial, "hidden Tasks resize \(step)")
            requireSize(2, initial, "hidden Events resize \(step)")
        }
        precondition(model.probes[1].distinctResizeCount == hiddenResizeCounts[1]
                     && model.probes[2].distinctResizeCount == hiddenResizeCounts[2],
                     "Inactive native editors received live-resize frames")
        print("PASS: 12 window resize steps update only active Chat; hidden Tasks/Events keep their initial viewport")

        let lastChatSize = CGSize(width: 600, height: 588)
        select(1, viewport: lastChatSize, context: "spring Chat→Tasks after live resize")
        requireSize(0, lastChatSize, "switch to Tasks")
        requireSize(1, lastChatSize, "switch to Tasks")
        requireSize(2, initial, "switch to Tasks")
        let afterTaskSelection = model.probes[1].distinctResizeCount
        for _ in 0..<4 { host.needsLayout = true; settle() }
        precondition(model.probes[1].distinctResizeCount == afterTaskSelection,
                     "Selecting a tab must settle without repeated native frame updates")
        let taskSize = CGSize(width: 420, height: 460)
        resize(taskSize)
        requireSize(0, lastChatSize, "Tasks active resize")
        requireSize(1, taskSize, "Tasks active resize")
        requireSize(2, initial, "Tasks active resize")

        select(2, viewport: taskSize, context: "spring Tasks→Events with stale cached size")
        requireSize(0, lastChatSize, "switch to Events")
        requireSize(1, taskSize, "switch to Events")
        requireSize(2, taskSize, "switch to Events")
        let eventSize = CGSize(width: 560, height: 620)
        resize(eventSize)
        requireSize(0, lastChatSize, "Events active resize")
        requireSize(1, taskSize, "Events active resize")
        requireSize(2, eventSize, "Events active resize")
        select(0, viewport: eventSize, context: "spring Events→Chat with stale cached size")
        requireSize(0, eventSize, "return to Chat")
        requireSize(1, taskSize, "return to Chat")
        requireSize(2, eventSize, "return to Chat")
        print("PASS: selecting a tab adopts the current viewport once; inactive siblings retain their last placed dimensions")

        select(1, viewport: eventSize, context: "repeated Chat→Tasks")
        let narrow = CGSize(width: 340, height: 420)
        resize(narrow)
        requireSize(0, eventSize, "hidden Chat during narrow Tasks resize")
        requireSize(2, eventSize, "hidden Events during narrow Tasks resize")
        select(2, viewport: narrow, context: "spring Tasks→Events after shrinking")
        select(0, viewport: narrow, context: "spring Events→Chat after shrinking")

        for index in model.probes.indices {
            let probe = model.probes[index], native = probe.view!
            precondition(probe.creationCount == 1 && ObjectIdentifier(native) == identities[index], "Tab native view was recreated")
            precondition(native.editor.string == drafts[index], "Unsent editor text was lost")
            precondition(native.editor.selectedRange() == NSRange(location: 7, length: 3), "Native text selection was lost")
            precondition(abs(native.contentView.bounds.origin.y - scrollOrigins[index]) < 0.5,
                         "Tab scroll position moved while switching/resizing: \(index)")
        }
        print("PASS: all three native editors preserve identity, unsent mixed-language text, selection and scroll position")
    }
}

@MainActor private final class RetainedTabFixtureModel: ObservableObject {
    @Published var activeIndex = 0
    let probes = (0..<3).map { _ in NativeTabProbe() }
}
@MainActor private final class NativeTabProbe {
    weak var view: RetainedTabNativeEditor?
    var creationCount = 0
    var distinctResizeCount = 0
    var frameSizes: [CGSize] = []
}
private struct RetainedTabFixture: View {
    @ObservedObject var model: RetainedTabFixtureModel
    var body: some View {
        PicoRetainedTabLayout(activeIndex: model.activeIndex) {
            ForEach(model.probes.indices, id: \.self) { index in
                RetainedTabEditorSurface(probe: model.probes[index])
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(model.activeIndex == index ? 1 : 0)
                    .allowsHitTesting(model.activeIndex == index)
                    .accessibilityHidden(model.activeIndex != index)
            }
        }.transaction(value: model.activeIndex) { transaction in
            // Same boundary as PicoAppView. Header spring remains outside it;
            // ordinary editor/content animations keep their own transactions.
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
}
private struct RetainedTabEditorSurface: NSViewRepresentable {
    let probe: NativeTabProbe
    func makeNSView(context: Context) -> RetainedTabNativeEditor {
        let view = RetainedTabNativeEditor()
        view.probe = probe; probe.view = view; probe.creationCount += 1
        return view
    }
    func updateNSView(_ view: RetainedTabNativeEditor, context: Context) {}
}
private final class RetainedTabNativeEditor: NSScrollView {
    weak var probe: NativeTabProbe?
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 2400))
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        editor.font = .systemFont(ofSize: 14)
        editor.isRichText = false
        editor.minSize = NSSize(width: 0, height: 2400)
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        documentView = editor
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func setFrameSize(_ newSize: NSSize) {
        if frame.size != newSize {
            probe?.distinctResizeCount += 1
            probe?.frameSizes.append(newSize)
        }
        super.setFrameSize(newSize)
    }
}
