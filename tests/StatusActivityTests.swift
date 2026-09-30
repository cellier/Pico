import AppKit
@main struct StatusActivityTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let original = NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!
        button.image = original
        let indicator = StatusActivityIndicator(button: button)
        let statuses = ["running", "running", "awaiting_approval", "ready", "paused", "completed", "error", "needs_input"]
        let tasks = statuses.map { status in var task = Todo(title: status); task.status = status; return task }
        precondition(StatusActivityIndicator.runningCount(tasks) == 2)
        indicator.update(count: 2, reduceMotion: false)
        let key = StatusActivityIndicator.animationKey
        precondition(indicator.iconView.rotationLayer.animation(forKey: key) != nil)
        precondition(button.toolTip == "Telos — 2 tasks running")
        let turn = indicator.iconView.rotationLayer.animation(forKey: key) as! CAKeyframeAnimation
        precondition(turn.keyPath == "transform.rotation.z" && turn.duration == 2.5)
        let values = (turn.values as! [NSNumber]).map(\.doubleValue)
        precondition(values.count == 3 && values[0] == 0 && values[1] == -2 * Double.pi && values[1] == values[2])
        // Clockwise in the icon's unflipped AppKit plane, including across each pause.
        precondition(!indicator.iconView.isFlipped)
        precondition(values.last == -2 * Double.pi)
        precondition(zip(values, values.dropFirst()).allSatisfy { $1 <= $0 })
        precondition(button.image == nil)
        precondition(indicator.iconView.hitTest(.zero) == nil)
        indicator.iconView.layoutSubtreeIfNeeded()
        precondition(indicator.iconView.rotationLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        precondition(indicator.iconView.rotationLayer.position == CGPoint(x: 8, y: 8))
        // AppKit layout changes the host origin, never the icon's local rotation center.
        indicator.iconView.setFrameOrigin(NSPoint(x: 37, y: 11))
        indicator.iconView.needsLayout = true; indicator.iconView.layoutSubtreeIfNeeded()
        precondition(indicator.iconView.rotationLayer.position == CGPoint(x: 8, y: 8))
        precondition(indicator.iconView.layer?.animation(forKey: key) == nil)
        indicator.update(count: 1, reduceMotion: false)
        precondition(indicator.iconView.rotationLayer.animationKeys()?.count == 1)
        indicator.update(count: 1, reduceMotion: true)
        precondition(indicator.iconView.rotationLayer.animation(forKey: key) == nil)
        precondition(indicator.iconView.superview === button)
        indicator.update(count: 1, reduceMotion: false)
        precondition(indicator.iconView.rotationLayer.animation(forKey: key) != nil)
        indicator.update(count: 0, reduceMotion: false)
        precondition(indicator.iconView.rotationLayer.animation(forKey: key) == nil)
        precondition(button.toolTip == "Telos" && button.image == nil && indicator.iconView.superview === button)
        let width = indicator.setEvent("9:00 AM · Calendar review")
        precondition(width > 100 && width <= 480)
        button.setFrameSize(NSSize(width: width, height: 24)); indicator.layout()
        indicator.update(count: 1, reduceMotion: false)
        indicator.iconView.layoutSubtreeIfNeeded()
        precondition(indicator.iconFrame.minX == 5 && indicator.iconFrame.width == 16)
        precondition(indicator.iconView.rotationLayer.position == CGPoint(x: 8, y: 8))
        precondition(button.toolTip?.contains("Calendar review") == true)
        precondition(indicator.setEvent(String(repeating: "long event ", count: 100)) == 480)
        _ = indicator.setEvent(nil)
        precondition(!button.toolTip!.contains("Calendar review"))
        print("PASS: active task count, clockwise full turns with pauses, reduced motion changes, idle cleanup")
    }
}
