import AppKit
import SwiftUI

/// Keep the small grab target above the transcript's native NSScrollView. A
/// SwiftUI drag overlay can otherwise lose mouse events to its NSClipView.
struct PicoTaskDetailGrabArea: NSViewRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> PicoTaskDetailGrabView {
        let view = PicoTaskDetailGrabView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: PicoTaskDetailGrabView, context: Context) {
        view.changed = changed; view.ended = ended
    }
}

final class PicoTaskDetailGrabView: NSView {
    var changed: (CGFloat) -> Void = { _ in }
    var ended: (CGFloat, CGFloat) -> Void = { _, _ in }
    private var start: NSPoint?
    private var previousY: CGFloat = 0
    private var previousTime: TimeInterval = 0
    private var velocity: CGFloat = 0
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow
        previousY = event.locationInWindow.y; previousTime = event.timestamp; velocity = 0
        window?.makeFirstResponder(nil)
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let interval = event.timestamp - previousTime
        if interval > 0 { velocity = (previousY - event.locationInWindow.y) / interval }
        previousY = event.locationInWindow.y; previousTime = event.timestamp
        // Window coordinates remain fixed as the sheet itself moves.
        changed(max(0, start.y - event.locationInWindow.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let distance = max(0, start.y - event.locationInWindow.y)
        let recentVelocity = event.timestamp - previousTime < 0.15 ? max(0, velocity) : 0
        self.start = nil
        NSCursor.openHand.set()
        ended(distance, distance + recentVelocity * 0.16)
    }
}
