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
            precondition(delegate.statusItem.button?.cell?.isHighlighted == false, "Closed panel must clear highlight")
            delegate.showPanel(); settle(); let after = scroll.contentView.bounds.origin.y
            precondition(delegate.statusItem.button?.cell?.isHighlighted == true, "Visible panel must keep highlight")
            precondition(abs(before - requested) < 0.5)
            precondition(abs(hidden - before) < 0.5, "Closing changed scroll position")
            precondition(abs(after - before) < 0.5, "Reopening changed scroll position")
            print("PASS position", requested, "preserved through hide/show")
        }
        func verifyAnimatedTip(for duration: TimeInterval) {
            let view = delegate.window.contentView!
            let layer = view.layer!
            let point = delegate.panelAnimationAnchor
            let x = point.x - layer.bounds.width * layer.anchorPoint.x
            let y = (layer.isGeometryFlipped == view.isFlipped ? point.y : view.bounds.height - point.y)
                - layer.bounds.height * layer.anchorPoint.y
            let deadline = Date().addingTimeInterval(duration)
            var frames = 0
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 120))
                let t = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
                precondition(abs(t.m41 + t.m11 * x - x) < 0.25, "Rendered animation moved arrow tip horizontally")
                precondition(abs(t.m42 + t.m22 * y - y) < 0.25, "Rendered animation moved arrow tip vertically")
                frames += 1
            } while Date() < deadline
            print("PASS fixed arrow tip across", frames, "presentation-layer samples")
        }
        delegate.hidePanel()
        let view = delegate.window.contentView!
        let layer = view.layer!
        let transform = layer.sublayerTransform
        let pivot = delegate.panelAnimationAnchor
        let outlineTip = StatusPanelOutline(anchorX: delegate.presentation.anchorX).arrowTip(in: view.bounds)
        precondition(abs(pivot.x - outlineTip.x) < 0.001)
        precondition(abs((view.isFlipped ? pivot.y : view.bounds.height - pivot.y) - outlineTip.y) < 0.001,
                     "Animation pivot must be the visible arrow tip")
        let expectedY = layer.isGeometryFlipped == view.isFlipped ? pivot.y : view.bounds.height - pivot.y
        precondition(abs(transform.m41 + layer.bounds.width * layer.anchorPoint.x - pivot.x) < 0.5, "Collapse must align with arrow tip X")
        precondition(abs(transform.m42 + layer.bounds.height * layer.anchorPoint.y - expectedY) < 0.5, "Collapse must align with arrow tip Y")
        print("PASS collapse target aligns with visible arrow tip")
        verifyAnimatedTip(for: 0.30)
        precondition(!delegate.window.isVisible, "Close must remove the window without a half-second settling tail")
        delegate.showPanel(); verifyAnimatedTip(for: 0.55)
        print("PASS close removes window within 300 ms")
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
