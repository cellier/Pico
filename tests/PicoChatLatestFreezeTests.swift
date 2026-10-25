import AppKit
import SwiftUI

/// Replays the latest-button freeze through the real window shell, with retained
/// Tasks and Events. Optional fixture paths are read-only, never the write profile.
/// PICO_JUMP_PRIVATE_FIXTURE=/copied/chat.json
/// PICO_JUMP_TASK_FIXTURE=/copied/tasks.json
/// PICO_JUMP_NATIVE_KEY=1 additionally requires launching this executable inside
/// its own QA .app bundle; background CLI launches cannot acquire app activation.
@main struct PicoChatLatestFreezeTests {
    @MainActor static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let environment = ProcessInfo.processInfo.environment
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicoRootJump-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: directory)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW", "TELOS_PERF_TRANSCRIPT", "TELOS_PREVIEW_APPEARANCE"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let fixture: URL
        let bytes: Data
        if let path = environment["PICO_JUMP_PRIVATE_FIXTURE"] {
            fixture = URL(fileURLWithPath: path)
            bytes = try Data(contentsOf: fixture)
        } else {
            struct Snapshot: Encodable {
                let conversationID = UUID()
                let messages: [Message]
                let artifacts: [Artifact] = []
                let status = "idle"
            }
            let paragraph = "A concise answer in English 与中文 mixed together, followed by a useful list.\n\n**Details**\n- A short first point.\n- A longer second point that wraps naturally at small widths.\n- Another point with **bold text**.\n\n1. Check the first result.\n2. Keep the original message.\n\nFinished."
            let messages = (0..<38).map { index in
                Message(role: index.isMultiple(of: 2) ? "user" : "assistant",
                        text: index.isMultiple(of: 2) ? "Question \(index) — 请解释一下这个功能。" : String(repeating: paragraph + "\n\n", count: index.isMultiple(of: 3) ? 4 : 1),
                        date: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 65))
            }
            fixture = directory.appendingPathComponent("fixture-chat.json")
            bytes = try JSONEncoder().encode(Snapshot(messages: messages))
            try bytes.write(to: fixture)
        }
        let profile = directory.appendingPathComponent("profile")
        setenv("TELOS_DATA_DIR", profile.path, 1)
        setenv("TELOS_PREVIEW", "chat-perf", 1)
        setenv("TELOS_PERF_TRANSCRIPT", fixture.path, 1)
        // Exercise the real AppStorage updates rather than a fixed preview override.
        unsetenv("TELOS_PREVIEW_APPEARANCE")
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 70)
        watchdog.setEventHandler { fputs("FAIL real-root latest jump: total test deadline exceeded\n", stderr); exit(70) }
        watchdog.resume()
        defer { watchdog.cancel() }
        let app = NSApplication.shared
        precondition(app.delegate == nil)
        precondition(Bundle.main.bundleIdentifier != "com.telos.mac",
                     "Run this regression as its own executable, never the installed app")
        let exercisesNativeKey = environment["PICO_JUMP_NATIVE_KEY"] == "1"
        if exercisesNativeKey {
            precondition(Bundle.main.bundleIdentifier != nil, "Native key coverage requires a launched QA .app bundle")
            app.setActivationPolicy(.regular)
            app.finishLaunching()
        } else { app.setActivationPolicy(.accessory) }
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let defaults = UserDefaults.standard
        let savedAppearance = defaults.object(forKey: PicoAppearance.preference)
        defer {
            if let savedAppearance { defaults.set(savedAppearance, forKey: PicoAppearance.preference) }
            else { defaults.removeObject(forKey: PicoAppearance.preference) }
        }
        PicoAppearance.dark.save(in: defaults)
        let store = TaskStore()
        if let path = environment["PICO_JUMP_TASK_FIXTURE"] {
            store.tasks = try JSONDecoder().decode([Todo].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } else {
            store.tasks = (0..<48).map { Todo(title: "Saved task \($0)", status: "ready") }
        }
        let taskEncoder = JSONEncoder()
        taskEncoder.outputFormatting = [.sortedKeys]
        let originalTasks = try taskEncoder.encode(store.tasks)
        store.selected = nil
        let presentation = PanelPresentation()
        let host = PanelHostingView(rootView: StatusPanelRoot(store: store, presentation: presentation))
        host.sizingOptions = []; host.safeAreaRegions = []
        host.wantsLayer = true; host.layer?.masksToBounds = true
        let window = TelosWindow(contentRect: NSRect(x: -4000, y: -4000, width: 471, height: 656),
                                 styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        window.minSize = NSSize(width: 220, height: 140)
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        let focusWindow = TelosWindow(contentRect: NSRect(x: -4000, y: -4200, width: 220, height: 140),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        focusWindow.isReleasedWhenClosed = false
        focusWindow.contentView = NSTextField(labelWithString: "Private focus regression fixture")
        defer { focusWindow.orderOut(nil) }
        var previous = Date(), maximumDelay: Double = 0
        let progress = PicoLatestTestProgress()
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date(); maximumDelay = max(maximumDelay, now.timeIntervalSince(previous)); previous = now
                progress.touch()
            }
        }
        defer { heartbeat.invalidate() }
        let starvation = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        starvation.schedule(deadline: .now() + 3, repeating: 0.5)
        starvation.setEventHandler {
            if progress.stalled {
                fputs("FAIL real-root latest jump: main heartbeat starved for 3 seconds\n", stderr)
                exit(71)
            }
        }
        starvation.resume()
        defer { starvation.cancel() }
        func settle(_ seconds: Double) {
            guard exercisesNativeKey else {
                RunLoop.main.run(until: Date().addingTimeInterval(seconds)); return
            }
            // App-active notifications arrive as AppKit events. A CF run loop
            // alone does not dispatch them while this synchronous fixture runs.
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
                app.updateWindows()
                _ = RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.004)))
            }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func probe() -> PicoChatScrollProbeView {
            descendants(host).compactMap { $0 as? PicoChatScrollProbeView }.first!
        }
        func scroll() -> NSScrollView { probe().enclosingScrollView! }
        func controller() -> PicoChatScrollController { probe().controller! }
        func maximum() -> CGFloat { max(0, scroll().documentView!.bounds.height - scroll().contentView.bounds.height) }
        func offset() -> CGFloat {
            let s = scroll(), doc = s.documentView!
            return doc.isFlipped ? s.contentView.bounds.minY : doc.bounds.maxY - s.contentView.bounds.maxY
        }
        func userScroll(_ fraction: CGFloat) {
            let s = scroll(), doc = s.documentView!, y = maximum() * fraction
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: s)
            let native = doc.isFlipped ? y : doc.bounds.maxY - s.contentView.bounds.height - y
            s.contentView.scroll(to: CGPoint(x: 0, y: native)); s.reflectScrolledClipView(s.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: s)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: s)
        }
        func nodes(_ root: Any) -> [NSObject] {
            guard let value = root as? NSObject else { return [] }
            let children = (value as? any NSAccessibilityProtocol)?.accessibilityChildren()
                ?? (value.accessibilityAttributeValue(.children) as? [Any]) ?? []
            return [value] + children.flatMap(nodes)
        }
        func label(_ value: NSObject) -> String {
            let selector = NSSelectorFromString("accessibilityLabel")
            if value.responds(to: selector), let label = value.perform(selector)?.takeUnretainedValue() as? String { return label }
            return value.accessibilityAttributeValue(.description) as? String ?? ""
        }
        func press(_ name: String) {
            guard let button = nodes(host).first(where: { label($0) == name && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) }) else { fatalError("Missing actual control: " + name) }
            let selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            precondition(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
        }
        func settingsAndAppearanceCycle() {
            print("STAGE settings open; Light → System → Dark")
            // Mount the actual Settings surface without running its unrelated
            // permission-check command from the header's action.
            store.showMacAccess = true; settle(0.25)
            precondition(store.showMacAccess)
            for mode in [PicoAppearance.light, .system, .dark] {
                mode.save(in: defaults)
                // AppDelegate normally applies this native counterpart. This
                // executable deliberately has no active app delegate or workers.
                window.appearance = mode.nativeAppearance
                settle(0.25)
            }
            press("Close settings"); settle(0.3)
            precondition(!store.showMacAccess)
            print("STAGE retained Tasks → Events → Chat")
            for tab in ["Tasks", "Events", "Chat"] { press(tab); settle(0.25) }
            precondition(!store.showMacAccess && store.selected == nil)
        }
        func hideAndShowPanel() {
            print("STAGE animate presentation closed, orderOut, reopen")
            window.makeFirstResponder(nil)
            presentation.closing = true; presentation.shown = false
            window.ignoresMouseEvents = true
            let anchor = CGPoint(x: host.bounds.midX, y: host.bounds.midY)
            host.animatePresentation(shown: false, anchor: anchor, reduced: false)
            settle(PanelHostingView.closeDuration)
            window.orderOut(nil); window.ignoresMouseEvents = false
            settle(0.4)
            precondition(!window.isVisible)
            presentation.closing = false
            window.orderBack(nil)
            presentation.shown = true
            host.animatePresentation(shown: true, anchor: anchor, reduced: false)
            settle(0.6)
            precondition(window.isVisible)
        }
        func activateMainPanel() {
            guard exercisesNativeKey else { return }
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            settle(0.2)
            precondition(window.isKeyWindow, "The native selection regression requires an actually key panel")
        }
        func resignAndRestorePanel() {
            guard exercisesNativeKey else { return }
            print("STAGE actual key-window and application deactivation")
            activateMainPanel()
            focusWindow.makeKeyAndOrderFront(nil); settle(0.2)
            precondition(!window.isKeyWindow && focusWindow.isKeyWindow)
            app.deactivate(); settle(0.3)
            precondition(!app.isActive, "The regression must reach the native inactive state")
            focusWindow.orderOut(nil)
            activateMainPanel()
        }
        print("STAGE mount actual PanelHostingView/StatusPanelRoot; both inactive tabs retained")
        if !exercisesNativeKey { print("SKIP app-active/key changes: CLI fixture; validated separately in the installed app") }
        settle(1)
        presentation.shown = true
        host.animatePresentation(shown: true, anchor: CGPoint(x: host.bounds.midX, y: host.bounds.midY), reduced: false)
        settle(0.6)
        activateMainPanel()
        for (index, size) in [CGSize(width: 471, height: 656), CGSize(width: 360, height: 480), CGSize(width: 600, height: 600), CGSize(width: 220, height: 140), CGSize(width: 471, height: 656)].enumerated() {
            print("STAGE resize \(index) \(size)")
            window.setContentSize(size); settle(0.3)
            if index.isMultiple(of: 2) {
                settingsAndAppearanceCycle()
                hideAndShowPanel()
                resignAndRestorePanel()
            }
            userScroll(0.45); settle(0.3)
            print("STAGE jump \(index) offset=\(Int(offset())) doc=\(Int(maximum()))")
            press("Jump to latest message"); settle(2.6)
            precondition(!controller().isAnimatingLatest && controller().followingLatest)
            let frames = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
            precondition(frames["picoLatest"] != nil)
            print("STAGE complete \(index) offset=\(Int(offset())) maximum=\(Int(maximum())) delay=\(maximumDelay)")
            if index.isMultiple(of: 2) { resignAndRestorePanel() }
        }
        let after = try Data(contentsOf: fixture)
        precondition(after == bytes)
        let unchangedTasks = try taskEncoder.encode(store.tasks)
        precondition(unchangedTasks == originalTasks, "Latest navigation must not change saved tasks")
        precondition(!FileManager.default.fileExists(atPath: profile.appendingPathComponent("chat.json").path))
        precondition(maximumDelay < 1, "Root jump main-loop lag \(maximumDelay)")
        let nativeCoverage = exercisesNativeKey ? "native activation/resign, " : ""
        print("PASS real-root latest jumps after \(nativeCoverage)hide/show animation, appearance/settings/retained-tab updates, min-size and repeated resize; private bytes unchanged")
    }
}

private final class PicoLatestTestProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBeat = ProcessInfo.processInfo.systemUptime
    func touch() {
        lock.lock(); defer { lock.unlock() }
        lastBeat = ProcessInfo.processInfo.systemUptime
    }
    var stalled: Bool {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastBeat > 3
    }
}
