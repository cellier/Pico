import AppKit

@main struct PanelScrollTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.7)) }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        delegate.store.tasks += (0..<30).map { Todo(title: "Task \($0)") }
        settle()
        let all = scrollViews(delegate.window.contentView!)

        guard let scroll = all.filter({($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 50}).max(by: {$0.bounds.width < $1.bounds.width}) else { fatalError("No scrollable task list") }
        precondition(abs(scroll.contentView.bounds.origin.y) < 0.5, "First opening must start at top")
        for requested in [CGFloat(0),90,180,600,1200,90,0] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: requested)); scroll.reflectScrolledClipView(scroll.contentView)
            settle(); let before = scroll.contentView.bounds.origin.y
            delegate.hidePanel(); settle(); let hidden = scroll.contentView.bounds.origin.y
            precondition(delegate.statusItem.button?.state == .off, "Closing the window must leave a momentary status item")
            delegate.showPanel(); settle(); let after = scroll.contentView.bounds.origin.y
            precondition(delegate.statusItem.button?.state == .off, "Opening the independent window must not latch the status item")
            precondition(abs(before - requested) < 0.5)
            precondition(abs(hidden - before) < 0.5, "Closing changed scroll position")
            precondition(abs(after - before) < 0.5, "Reopening changed scroll position")
            print("PASS position", requested, "preserved through hide/show")
        }
        let preservedFrame = delegate.window.frame
        delegate.hidePanel(); settle()
        precondition(!delegate.window.isVisible, "Hide must remove the window promptly")
        delegate.showPanel(); settle()
        precondition(delegate.window.frame == preservedFrame, "Floating window must preserve its geometry")
        print("PASS independent window hide/reopen without popover anchoring")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 420))
        scroll.reflectScrolledClipView(scroll.contentView)
        delegate.hidePanel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        delegate.showPanel(); settle()
        precondition(delegate.window.isVisible && delegate.panelShown)
        precondition(abs(scroll.contentView.bounds.origin.y - 420) < 0.5, "Interrupted transition moved scroll")
        NotificationCenter.default.post(name: .init("TelosTaskTop"), object: nil)
        settle()
        precondition(abs(scroll.contentView.bounds.origin.y) < 0.5, "Double-click Task must return to top")
        print("PASS rapid reopen and explicit return to top")
        delegate.window.orderOut(nil)
        delegate.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
    }
}
