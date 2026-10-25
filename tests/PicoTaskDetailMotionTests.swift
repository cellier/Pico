import AppKit
import SwiftUI
import QuartzCore

private func require(_ condition: @autoclosure () -> Bool,
                     _ message: @autoclosure () -> String = "Condition failed", line: UInt = #line) {
    guard condition() else {
        print("FAIL MotionTests:\(line): \(message())")
        exit(70)
    }
}

/// Drive the actual RootView presentation using private inert tasks. Native
/// frame sampling catches a fade-only sheet, an expanding native viewport and
/// text disappearing before dismissal reaches the bottom of the window.
@main struct PicoTaskDetailMotionTests {
    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("pico-detail-motion-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("TELOS_DATA_DIR", data.path, 1)
        setenv("TELOS_PREVIEW", "detail", 1)
        defer {
            try? FileManager.default.removeItem(at: data)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            print("SKIP animated travel: the system has Reduce Motion enabled; the preference was not changed")
            return
        }
        let store = TaskStore()
        let first = store.selectedTask!.id, second = store.tasks[1].id
        store.selected = nil
        let initialIDs = store.tasks.map(\.id)
        let initialStates = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.status) })
        let initialMessages = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.messages.map(\.id)) })
        let host = NSHostingView(rootView: RootView(store: store))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 374, height: 528),
                                 styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.isReleasedWhenClosed = false
        window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        // The renderer must remain visible: WindowServer can throttle a fully
        // occluded app. Present a private window without activating or focusing.
        window.level = .floating
        window.center(); window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func tick(_ seconds: Double = 1 / 120) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func topRect(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: host)
            return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func presentedTopRect(_ view: NSView) -> CGRect {
            guard let layer = view.layer, let root = host.layer,
                  let presentation = layer.presentation(), let rootPresentation = root.presentation() else {
                return topRect(view)
            }
            let rect = presentation.convert(presentation.bounds, to: rootPresentation)
            return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func grab() -> PicoTaskDetailGrabView? { descendants(host).compactMap { $0 as? PicoTaskDetailGrabView }.first }
        func editor() -> AttachmentTextView? {
            descendants(host).compactMap { $0 as? AttachmentTextView }.first { $0.accessibilityIdentifier() == "askField" }
        }
        var expectedNativeFrames: [CGRect]?
        var expectedEditorHeight: CGFloat?
        var expectedEditorFont: CGFloat?
        var phase = "initial"
        var geometryFailures: [String] = []
        func geometryRequire(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
            if !condition(), geometryFailures.count < 5 {
                let bounds = descendants(host).compactMap { $0 as? NSScrollView }
                    .filter { abs($0.bounds.width - host.bounds.width) <= 0.5 }
                    .map { view in
                        var layer: CALayer? = view.layer
                        var layers: [String] = []
                        while let item = layer, layers.count < 8 {
                            layers.append("\(type(of: item)) name=\(item.name ?? "") bounds=\(item.bounds) mask=\(String(describing: item.mask?.bounds)) clips=\(item.masksToBounds)")
                            layer = item.superlayer
                        }
                        return "\(type(of: view)): bounds=\(view.bounds.size), clip=\(view.contentView.bounds.size), layers=\(layers)"
                    }
                geometryFailures.append(message() + "; window=\(window.frame), host=\(host.bounds.size), nativeBounds=\(bounds)")
            }
        }
        func nativeFrames(_ size: CGSize) -> [CGRect] {
            guard let grab = grab() else { return [] }
            let top = topRect(grab).minY
            return descendants(host).compactMap { $0 as? NSScrollView }
                .filter { abs($0.bounds.width - size.width) <= 0.5 && $0.bounds.height > 0 }
                .map { topRect($0).offsetBy(dx: 0, dy: -top) }
                .sorted { $0.minY < $1.minY }
        }
        func surfaceLayer(_ size: CGSize) -> CALayer? {
            guard let scroll = descendants(host).compactMap({ $0 as? NSScrollView })
                .first(where: { abs($0.bounds.width - size.width) <= 0.5 && $0.bounds.height > 0 }) else { return nil }
            var current = scroll.layer
            var surface: CALayer?
            while let layer = current, layer !== host.layer {
                if abs(layer.bounds.width - host.bounds.width) <= 0.5 {
                    // The final graphics container before the full-window
                    // graphics root is the actual, fixed card surface.
                    if abs(layer.bounds.height - host.bounds.height) <= 0.5 { return surface }
                    surface = layer
                }
                current = layer.superlayer
            }
            return surface
        }
        func nativeSheetGeometry(_ expected: CGSize) {
            guard let grab = grab() else { return }
            let frame = topRect(grab)
            geometryRequire(abs(frame.width - 90) <= 0.5 && abs(frame.midX - expected.width / 2) <= 0.5,
                         "The sheet must translate vertically without horizontal scaling or drifting")
            let frames = nativeFrames(expected)
            geometryRequire(!frames.isEmpty, "The real detail transcript must keep its final full width while moving")
            if let surface = surfaceLayer(expected), let root = host.layer {
                let rendered = surface.presentation() ?? surface
                let rootRendered = root.presentation() ?? root
                let pixels = rendered.convert(rendered.bounds, to: rootRendered)
                geometryRequire(abs(pixels.width - expected.width) <= 0.5 && abs(pixels.height - (expected.height - 56)) <= 0.5,
                                "The rendered card surface expanded or scaled during \(phase): \(pixels.size)")
                let transform = rendered.transform
                geometryRequire(abs(transform.m11 - 1) < 0.001 && abs(transform.m22 - 1) < 0.001 && abs(transform.m12) < 0.001 && abs(transform.m21) < 0.001,
                                "The actual card must only translate, without scaling its text")
            } else { geometryRequire(false, "The actual fixed card surface layer was not found") }
            if let reference = expectedNativeFrames {
                geometryRequire(frames.count == reference.count, "The sheet's native viewport structure changed during motion")
                for (actual, final) in zip(frames, reference) {
                    // SwiftUI's native bridge reserves up to two points of
                    // vertical raster backing. Allocation may be asymmetric,
                    // including after content replacement; the actual graphics
                    // surface above must remain exactly the final card height.
                    let topOutset = final.minY - actual.minY
                    let bottomOutset = actual.maxY - final.maxY
                    geometryRequire(abs(actual.width - final.width) <= 0.5 && topOutset >= -0.5 && topOutset <= 2.1 && bottomOutset >= -0.5 && bottomOutset <= 2.1 && topOutset + bottomOutset <= 2.1,
                                    "Native transcript changed beyond two-point total raster allocation during \(phase): \(actual) vs \(final)")
                    geometryRequire(abs(actual.minX - final.minX) <= 0.5,
                                    "Native content drifted horizontally during \(phase)")
                }
            }
            if let editor = editor(), let height = expectedEditorHeight {
                let nativeHeight = editor.enclosingScrollView!.bounds.height
                geometryRequire(nativeHeight >= height - 0.5 && nativeHeight <= height + 2.1,
                                "Editor backing changed beyond fractional-position raster overscan during \(phase)")
                if let pointSize = expectedEditorFont {
                    geometryRequire(abs((editor.font?.pointSize ?? 0) - pointSize) < 0.001,
                                    "Native text font changed during sheet translation")
                }
            }
        }
        var lastModelPositions: [CGFloat] = []
        @discardableResult func sample(_ size: CGSize, count: Int = 80, retaining draft: (AttachmentTextView, String)? = nil) -> [CGFloat] {
            var positions: [CGFloat] = []
            lastModelPositions = []
            geometryFailures = []
            for _ in 0..<count {
                tick()
                if let grab = grab() {
                    let y = presentedTopRect(grab).minY
                    positions.append(y)
                    lastModelPositions.append(topRect(grab).minY)
                    nativeSheetGeometry(size)
                    if let (original, text) = draft {
                        require(editor() === original && original.string == text,
                                     "Closing must retain the same native editor and unsent text until the sheet is removed")
                    }
                } else if draft != nil {
                    require(positions.last.map { $0 >= size.height - 32 } ?? false,
                                 "Detail content disappeared before its exit reached the window bottom")
                }
            }
            if phase == "entrance" || !geometryFailures.isEmpty {
                print("TRACE \(Int(size.width))x\(Int(size.height)) \(phase): model=\(lastModelPositions.prefix(24).map { Int($0.rounded()) }); rendered=\(positions.prefix(24).map { Int($0.rounded()) }); tail=\(positions.suffix(8).map { Int($0.rounded()) }); presentationLayer=\(grab()?.layer?.presentation() != nil)")
            }
            require(geometryFailures.isEmpty, geometryFailures.joined(separator: "\n"))
            return positions
        }
        func opened(_ size: CGSize, context: String) {
            guard let grab = grab() else { preconditionFailure("Sheet vanished: \(context)") }
            require(abs(topRect(grab).minY - 56) <= 1 && editor() != nil,
                         "The opened sheet must finish at the56pt top inset: \(context)")
            nativeSheetGeometry(size)
        }
        func closed(_ context: String) {
            require(grab() == nil && editor() == nil && store.selected == nil,
                         "A dismissed sheet must release its native content: \(context)")
        }
        tick(1)
        closed("initial hidden state")
        let allSizes = [CGSize(width: 220, height: 140), CGSize(width: 340, height: 420), CGSize(width: 374, height: 528), CGSize(width: 560, height: 720)]
        let sizes = environment["TELOS_MOTION_CASE"] == "minimum" ? [allSizes[0]] : environment["TELOS_MOTION_CASE"] == "normal" ? [allSizes[2]] : allSizes
        for size in sizes {
            window.setContentSize(size); window.center(); window.orderFrontRegardless(); tick(0.3)
            let originalFrame = window.frame
            phase = "settled baseline"
            // Establish settled final layout, then compare every intermediate
            // opening/closing frame against that exact native viewport. The
            // system's Reduce Motion preference is read-only; do not change a
            // global accessibility setting just to drive this private fixture.
            store.selected = first; tick(0.65)
            opened(size, context: "final native geometry baseline")
            expectedNativeFrames = nativeFrames(size)
            expectedEditorHeight = editor()!.enclosingScrollView!.bounds.height
            expectedEditorFont = editor()!.font!.pointSize
            let emptyFrames = expectedNativeFrames
            let emptyEditorHeight = expectedEditorHeight
            store.selected = nil; tick(0.65)
            closed("baseline dismissal")
            phase = "entrance"
            store.selected = first
            let opening = sample(size)
            print("TRACE \(Int(size.width))x\(Int(size.height)): model=\(lastModelPositions.prefix(24).map { Int($0.rounded()) }); rendered=\(opening.prefix(24).map { Int($0.rounded()) }); presentationLayer=\(grab()?.layer?.presentation() != nil)")
            require(opening.count >= 20 && opening.first! > size.height - 40,
                         "Entrance must start near the actual window bottom, got \(opening.prefix(8))")
            let intermediate = opening.filter { $0 > 64 && $0 < size.height - 20 }
            require(intermediate.count >= 5 && Set(opening.map { Int($0.rounded()) }).count >= 10,
                         "The sheet must visibly travel upward, not just fade in at its final position")
            opened(size, context: "entrance")
            let originalEditor = editor()!
            let draft = "未发 draft"
            originalEditor.insertText(draft, replacementRange: NSRange(location: 0, length: 0)); tick(0.1)
            require(originalEditor.string == draft)
            // CJK glyph metrics or line wrapping may legitimately resize the
            // composer while editing. Freeze that settled layout for its exit.
            expectedNativeFrames = nativeFrames(size)
            expectedEditorHeight = editor()!.enclosingScrollView!.bounds.height
            phase = "draft exit"
            store.selected = nil
            let closing = sample(size, retaining: (originalEditor, draft))
            require(closing.first.map { $0 < 100 } == true && closing.max().map { $0 >= size.height - 32 } == true,
                         "Exit must slide continuously back below the window")
            closed("normal close")
            require(window.isVisible && window.frame == originalFrame,
                         "Sheet motion must not move or hide its containing app window")
            print("PASS \(Int(size.width))x\(Int(size.height)):80 entrance frames from\(opening.first!)→\(opening.last!), fixed native width/height/relative position; exit retained editor/draft until below window")

            expectedNativeFrames = emptyFrames; expectedEditorHeight = emptyEditorHeight
            phase = "same-sheet task switch"
            store.selected = first; _ = sample(size)
            let firstNative = editor()!
            store.selected = second
            let switched = sample(size, count: 40)
            require(switched.allSatisfy { abs($0 - 56) <= 1 } && editor() !== firstNative,
                         "Changing the task in an open sheet must replace content without a new entrance")
            opened(size, context: "same-sheet task switch")
            store.selected = nil; _ = sample(size)
            closed("switched task close")

            phase = "rapid reopen"
            store.selected = first; _ = sample(size)
            let retainedEditor = editor()!
            retainedEditor.insertText(draft, replacementRange: NSRange(location: 0, length: 0)); tick(0.05)
            expectedNativeFrames = nativeFrames(size)
            expectedEditorHeight = editor()!.enclosingScrollView!.bounds.height
            store.selected = nil; tick(0.05)
            store.selected = first
            _ = sample(size)
            opened(size, context: "rapid close and reopen")
            require(editor() === retainedEditor && retainedEditor.string == draft,
                         "A stale close completion must not remove the reopened sheet or its draft")
            store.selected = nil; _ = sample(size)
            closed("rapid reopen final close")

            expectedNativeFrames = emptyFrames; expectedEditorHeight = emptyEditorHeight
            phase = "immediate close"
            store.selected = first; store.selected = nil
            _ = sample(size)
            closed("open and immediately close in one turn")
            store.selected = first; tick(0.002); store.selected = nil
            _ = sample(size)
            closed("close before queued entrance starts")
            expectedNativeFrames = nil
            expectedEditorHeight = nil
            expectedEditorFont = nil
            print("PASS \(Int(size.width))x\(Int(size.height)):same-sheet content switch, rapid reopen, stale-completion protection and immediate-close cancellation")
        }
        require(store.tasks.map(\.id) == initialIDs)
        require(Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.status) }) == initialStates)
        require(Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.messages.map(\.id)) }) == initialMessages,
                     "Motion tests must never send a draft or mutate conversation history")
        let files = FileManager.default.enumerator(at: data, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        let noRegularFiles = try files.allSatisfy { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true }
        require(noRegularFiles, "Read-only preview tests must not persist task files")
        print("PASS actual RootView sheet spring lifecycle,\(sizes.count) sizes, stable native geometry/content, unchanged private tasks and no user-data/global-pointer actions")
    }
}
