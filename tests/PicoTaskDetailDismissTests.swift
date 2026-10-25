import AppKit
import SwiftUI

/// Exercise the actual modal shell using inert private task data. All events are
/// delivered to this test's own window; the global pointer never moves.
@main struct PicoTaskDetailDismissTests {
    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("pico-detail-dismiss-" + UUID().uuidString)
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
        let store = TaskStore()
        precondition(store.dataDir.standardizedFileURL.path == data.standardizedFileURL.path)
        let selected = store.selectedTask!.id
        let initialIDs = Set(store.tasks.map(\.id))
        let initialStates = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.status) })
        let initialDates = Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.completedAt) })
        let host = NSHostingView(rootView: RootView(store: store))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 374, height: 528),
                                 styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host; window.isOpaque = false; window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua); window.level = .floating
        window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }

        func settle(_ seconds: Double = 0.5) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func topRect(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: host)
            return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            host.convert(NSPoint(x: x, y: host.isFlipped ? y : host.bounds.height - y), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, tick: Double) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime + tick,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: Int(tick * 1000) + 1, clickCount: 1,
                               pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func drainMouseEvents() {
            while let event = app.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: Date(), inMode: .default, dequeue: true) {
                guard event.windowNumber == window.windowNumber else { app.postEvent(event, atStart: true); break }
                app.sendEvent(event)
            }
        }
        func click(_ x: CGFloat, _ y: CGFloat) {
            let location = point(x, y)
            app.postEvent(mouse(.leftMouseUp, at: location, tick: 0.02), atStart: true)
            app.sendEvent(mouse(.leftMouseDown, at: location, tick: 0))
            drainMouseEvents(); settle()
        }
        func open() {
            store.showMacAccess = false
            if store.selected != nil { store.selected = nil; settle() }
            store.selected = selected
            settle()
            precondition(store.selected == selected, "Private fixture must reopen the same task")
        }
        func unchanged(_ context: String, frame: NSRect) {
            precondition(Set(store.tasks.map(\.id)) == initialIDs, "Dismissal must not create or delete tasks: \(context)")
            precondition(Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.status) }) == initialStates,
                         "Dismissal must not complete, start or change a task: \(context)")
            precondition(Dictionary(uniqueKeysWithValues: store.tasks.map { ($0.id, $0.completedAt) }) == initialDates,
                         "Dismissal must not archive a task: \(context)")
            precondition(!store.showMacAccess, "The dimmed avatar must not open settings: \(context)")
            precondition(window.isVisible && window.frame == frame, "Modal dismissal must not hide or move the app window: \(context)")
        }
        settle(0.8)
        for size in [NSSize(width: 374, height: 528), NSSize(width: 340, height: 420), NSSize(width: 560, height: 720)] {
            window.setContentSize(size); window.center(); window.makeKeyAndOrderFront(nil); settle()
            let frame = window.frame
            // These locations formerly belonged to the outer WindowDragGesture,
            // Search/avatar controls and the shell margin outside TaskBoard.
            let locations: [(String, CGFloat, CGFloat)] = [
                ("top margin", size.width / 2, 8),
                ("former Search", 34, 34),
                ("former tabs", size.width / 2, 34),
                ("former avatar", size.width - 34, 34),
                ("left scrim edge", 8, 50),
                ("right scrim edge", size.width - 8, 50),
                ("left rounded-corner scrim", 3, PicoTaskDetailMetrics.topInset + 2),
                ("right rounded-corner scrim", size.width - 3, PicoTaskDetailMetrics.topInset + 2)
            ]
            for (label, x, y) in locations {
                open(); click(x, y)
                precondition(store.selected == nil, "Visible upper scrim did not dismiss at \(label), \(size)")
                unchanged(label, frame: frame)
            }
            open()
            for x in [CGFloat(45), size.width - 45] {
                click(x, PicoTaskDetailMetrics.topInset + 2)
                precondition(store.selected == selected, "The solid top edge inside the rounded sheet must retain the detail")
            }
            unchanged("solid rounded top edge", frame: frame)
            click(size.width / 2, PicoTaskDetailMetrics.topInset + 100)
            precondition(store.selected == selected, "Clicking inside the sheet body must not dismiss")
            guard let editor = descendants(host).compactMap({ $0 as? AttachmentTextView }).first(where: { $0.accessibilityIdentifier() == "askField" }) else {
                fatalError("Task detail must retain its native composer")
            }
            let editorRect = topRect(editor)
            click(editorRect.midX, editorRect.midY)
            precondition(store.selected == selected && window.firstResponder === editor,
                         "Clicking the composer must focus its editor without dismissing")
            unchanged("body and composer", frame: frame)

            open()
            window.makeFirstResponder(host)
            // Figma's handle center is56pt + half its25pt grab region. A130pt
            // physical drag must remain130pt even as the sheet follows it.
            let start = point(size.width / 2, 68.5)
            let end = NSPoint(x: start.x, y: start.y - 130)
            let dragEvents = [(CGFloat(6), 0.03), (CGFloat(40), 0.08), (CGFloat(85), 0.13), (CGFloat(130), 0.18)].map { distance, tick in
                mouse(.leftMouseDragged,
                      at: NSPoint(x: start.x, y: start.y - distance), tick: tick)
            } + [mouse(.leftMouseUp, at: end, tick: 0.22)]
            for event in dragEvents.reversed() { app.postEvent(event, atStart: true) }
            app.sendEvent(mouse(.leftMouseDown, at: start, tick: 0))
            drainMouseEvents(); settle()
            precondition(store.selected == nil, "Dragging the existing handle downward must dismiss")
            unchanged("handle drag", frame: frame)

            open()
            guard let escapeEditor = descendants(host).compactMap({ $0 as? AttachmentTextView }).first(where: { $0.accessibilityIdentifier() == "askField" }) else {
                fatalError("Reopened task detail must retain its native composer")
            }
            let escapeEditorRect = topRect(escapeEditor)
            click(escapeEditorRect.midX, escapeEditorRect.midY)
            precondition(window.firstResponder === escapeEditor, "Escape acceptance must begin from the focused composer")
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                           isARepeat: false, keyCode: 53)!
            app.sendEvent(escape); settle()
            precondition(store.selected == nil, "Escape must dismiss the current task detail")
            unchanged("Escape", frame: frame)
            print("PASS \(Int(size.width))x\(Int(size.height)): eight upper/rounded-corner scrim hit regions, solid rounded edge/body/composer retention, handle drag, Escape, unchanged task states/window")
        }
        let files = FileManager.default.enumerator(at: data, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        let noRegularFiles = try files.allSatisfy { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true }
        precondition(noRegularFiles,
                     "Modal acceptance must not persist tasks or run a worker")
        print("PASS task-detail native dismissal, focused composer, no global pointer movement or user-data changes")
    }
}
