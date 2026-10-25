import AppKit
@main struct PicoWindowTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        func settle(_ seconds: Double = 0.7) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        settle()
        let window = delegate.window!
        precondition(window.title == "Pico")
        precondition(window.styleMask.contains(.resizable) && window.level == .floating)
        precondition(window.minSize.width <= 374 && window.minSize.height <= 528)
        precondition(window.maxSize.width > 800 && window.maxSize.height > 1000)
        let safe = (window.screen ?? NSScreen.main!).visibleFrame
        let resized = NSRect(x: min(window.frame.minX + 30, safe.maxX - 640), y: min(window.frame.minY + 20, safe.maxY - 820), width: 640, height: 820)
        window.setFrame(resized, display: true); settle(2.3)
        fputs("requested: \(resized) actual: \(window.frame)\n", stderr)
        precondition(window.frame == resized, "Status/calendar refresh must not reset a moved or resized window")
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: app)
        settle()
        precondition(window.isVisible && delegate.panelShown, "Another app must not dismiss the independent window")
        delegate.hidePanel(); settle()
        precondition(!window.isVisible)
        delegate.showPanel(); settle()
        precondition(window.frame == resized, "Reopening preserves position and dimensions")
        precondition(window.isVisible && delegate.panelShown)
        precondition(window.contentView?.bounds.size == resized.size)
        delegate.hidePanel(); settle()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS Pico branding, native resize, front level, frame preservation, no outside dismissal, reopen")
    }
}
