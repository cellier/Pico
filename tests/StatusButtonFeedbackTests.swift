import AppKit

/// Deterministic AppKit geometry, without moving the real pointer or interacting
/// with the secure desktop. The production controller still reads its real API.
private final class FeedbackTestWindow: NSWindow {
    var testPointer = NSPoint(x: -1000, y: -1000)
    override var mouseLocationOutsideOfEventStream: NSPoint { testPointer }
}

@main struct StatusButtonFeedbackTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let window = FeedbackTestWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 80), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 80))
        let button = NSButton(frame: NSRect(x: 10, y: 10, width: 24, height: 24))
        container.addSubview(button); window.contentView = container; window.orderFront(nil)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }
        settle()
        // AppKit may provide its own bezel subview once a native button is on
        // screen. The controller must preserve that hierarchy without additions.
        let originalSubviews = button.subviews.map(ObjectIdentifier.init)
        let feedback = StatusButtonFeedback(button: button)
        let cell = button.cell as! NSButtonCell
        precondition(feedback.responds(to: NSSelectorFromString("mouseEntered:")), "Tracking areas must find the actual AppKit mouseEntered: selector")
        precondition(feedback.responds(to: NSSelectorFromString("mouseExited:")), "Tracking areas must find the actual AppKit mouseExited: selector")
        precondition(cell.showsStateBy.isEmpty && cell.highlightsBy == [.changeBackgroundCellMask], "Only native momentary highlighting should paint the background")
        button.state = .on; button.highlight(true)
        feedback.syncAfterTracking()
        precondition(button.state == .off, "A previous window-visible selected state must clear immediately")
        settle()
        precondition(button.state == .off && !cell.isHighlighted && !feedback.isHovered)
        precondition(button.subviews.map(ObjectIdentifier.init) == originalSubviews, "Status hover feedback must not add an overlay or custom subview")
        let owned = button.trackingAreas.filter { $0.owner === feedback }
        precondition(owned.count == 1)
        let area = owned[0]
        precondition(area.options.contains([.mouseEnteredAndExited, .activeAlways, .inVisibleRect]))

        let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        feedback.mouseEntered(with: entered)
        precondition(feedback.isHovered && cell.isHighlighted && button.state == .off)
        feedback.mouseExited(with: exited)
        precondition(!feedback.isHovered && !cell.isHighlighted && button.state == .off)

        // A native mouse-up can clear its own press highlight; the queued refresh
        // must restore actual hover, while the button state always stays off.
        window.testPointer = NSPoint(x: 20, y: 20)
        feedback.syncAfterTracking(); button.highlight(false); settle()
        precondition(feedback.isHovered && cell.isHighlighted && button.state == .off)
        // A stale hover/action must not latch after the pointer leaves.
        for _ in 0..<30 { feedback.syncAfterTracking() }
        window.testPointer = NSPoint(x: -1000, y: -1000)
        feedback.mouseExited(with: exited); settle()
        precondition(!feedback.isHovered && !cell.isHighlighted && button.state == .off)

        button.setFrameSize(NSSize(width: 180, height: 24))
        window.testPointer = NSPoint(x: 165, y: 20)
        feedback.syncAfterTracking(); settle()
        precondition(feedback.isHovered && cell.isHighlighted, "The whole expanded calendar status item must respond to hover")
        precondition(button.trackingAreas.contains { $0 === area }, "inVisibleRect must adapt without accumulating tracking areas")
        button.setFrameSize(NSSize(width: 24, height: 24))
        feedback.syncAfterTracking(); settle()
        precondition(!feedback.isHovered && !cell.isHighlighted && button.state == .off, "Native visibleRect can exceed the button bounds; shrinking must clear hover outside its actual bounds")

        feedback.mouseEntered(with: entered); feedback.syncAfterTracking(); feedback.stop(); settle()
        precondition(!button.trackingAreas.contains { $0 === area })
        precondition(!feedback.isHovered && !cell.isHighlighted && button.state == .off)
        feedback.mouseEntered(with: entered); feedback.syncAfterTracking(); feedback.stop(); settle()
        precondition(!cell.isHighlighted && button.state == .off && button.subviews.map(ObjectIdentifier.init) == originalSubviews)
        var transient: StatusButtonFeedback? = StatusButtonFeedback(button: button)
        let transientArea = button.trackingAreas.first { $0.owner === transient }!
        transient = nil
        precondition(transientArea.owner == nil && !button.trackingAreas.contains { $0 === transientArea }, "Deinitialization must remove the weak-owner tracking area")
        print("PASS native status feedback: AppKit selectors, idle/hover/exit, native press style, delayed stale reset, dynamic width, no subviews, stop and deinit cleanup; no physical input")
    }
}
