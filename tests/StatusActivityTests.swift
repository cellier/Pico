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
        precondition(indicator.iconView.rotationLayer.animation(forKey: key) == nil)
        precondition(button.toolTip == "Pico — 2 tasks running")
        // Meeting, task and Chat activity all keep the date upright.
        precondition(!indicator.iconView.isFlipped)
        precondition(CATransform3DIsIdentity(indicator.iconView.rotationLayer.transform))
        precondition(button.image != nil)
        precondition(indicator.iconView.hitTest(.zero) == nil)
        indicator.iconView.layoutSubtreeIfNeeded()
        precondition(indicator.iconView.rotationLayer.anchorPoint == CGPoint(x: 0.5, y: 0.5))
        precondition(indicator.iconView.rotationLayer.position == CGPoint(x: 9, y: 9))
        precondition(indicator.iconFrame == NSRect(x: 3, y: 3, width: 18, height: 18))
        // AppKit layout changes the host origin, never the icon's local center.
        indicator.iconView.setFrameOrigin(NSPoint(x: 37, y: 11))
        indicator.iconView.needsLayout = true; indicator.iconView.layoutSubtreeIfNeeded()
        precondition(indicator.iconView.rotationLayer.position == CGPoint(x: 9, y: 9))
        precondition(indicator.iconView.layer?.animation(forKey: key) == nil)
        // A status update also clears any stale transform/animation left on the layer.
        let oldTurn = CABasicAnimation(keyPath: "transform.rotation.z")
        oldTurn.toValue = -2 * Double.pi; oldTurn.duration = 2.5; oldTurn.repeatCount = .infinity
        indicator.iconView.rotationLayer.add(oldTurn, forKey: key)
        indicator.iconView.rotationLayer.transform = CATransform3DMakeRotation(0.5, 0, 0, 1)
        for reduceMotion in [false, true] {
            for count in [1, 2, 12] {
                indicator.update(count: count, reduceMotion: reduceMotion)
                precondition(indicator.iconView.rotationLayer.animation(forKey: key) == nil)
                precondition(CATransform3DIsIdentity(indicator.iconView.rotationLayer.transform))
                precondition(button.toolTip == "Pico — \(count) tasks running")
            }
            let activeCount = indicator.renderedImageCount
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(indicator.renderedImageCount == activeCount, "Active tasks/meetings must not redraw from an animation timer")
        }
        precondition(indicator.iconView.superview === indicator.contentView)
        indicator.update(count: 0, reduceMotion: false)
        precondition(indicator.iconView.rotationLayer.animation(forKey: key) == nil)
        let stoppedCount = indicator.renderedImageCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(indicator.renderedImageCount == stoppedCount, "Idle icon must not keep rendering from an orphaned timer")
        precondition(button.toolTip == "Pico" && button.image != nil && indicator.iconView.superview === indicator.contentView)
        precondition(button.subviews.isEmpty, "Status items must not snapshot custom subviews")
        let rendered = indicator.renderedImageCount
        for _ in 0..<100 { indicator.update(count: 0, reduceMotion: false) }
        precondition(indicator.renderedImageCount == rendered, "Unchanged status must reuse its image")
        let allDay = CalendarMenuText(time: "All-day", title: "调休")
        let allDayWidth = indicator.setEvent(allDay)
        precondition(allDayWidth >= 80)
        button.setFrameSize(NSSize(width: allDayWidth, height: 24)); indicator.layout()
        precondition(indicator.contentView.subviews.compactMap { $0 as? NSTextField }.allSatisfy { !$0.isHidden }, "Short all-day labels must stay visible")
        precondition(StatusActivityIndicator.eventWidth(textWidth: 31, availableWidth: 320, thickness: 24) == 80)
        let sample = CalendarMenuText(time: "Tomorrow 9:00 AM", title: "1on1 meeting with 抗")
        let width = indicator.setEvent(sample)
        precondition(width > 100 && width <= 320)
        button.setFrameSize(NSSize(width: width, height: 24)); indicator.layout()
        indicator.update(count: 1, reduceMotion: false)
        indicator.iconView.layoutSubtreeIfNeeded()
        precondition(indicator.iconFrame.minX == 4 && indicator.iconFrame.width == 18)
        precondition(indicator.iconView.rotationLayer.position == CGPoint(x: 9, y: 9))
        precondition(button.toolTip?.contains(sample.title) == true)
        let labels = indicator.contentView.subviews.compactMap { $0 as? NSTextField }
        let timeLabel = labels.first { $0.stringValue == sample.time }!
        let titleLabel = labels.first { $0.stringValue == sample.title }!
        precondition(button.isFlipped ? timeLabel.frame.maxY <= titleLabel.frame.minY
            : timeLabel.frame.minY >= titleLabel.frame.maxY)
        precondition(timeLabel.font!.pointSize == 9 && titleLabel.font!.pointSize == 11)
        for height: CGFloat in [22, 24, 32] {
            button.setFrameSize(NSSize(width: width, height: height)); indicator.layout()
            precondition(labels.allSatisfy { $0.frame.minY >= 0 && $0.frame.maxY <= height })
            precondition(timeLabel.frame.minX == titleLabel.frame.minX)
            precondition(indicator.iconFrame.height == 18 && indicator.iconFrame.minY == (height - 18) / 2)
            precondition(indicator.iconFrame.minY >= 0 && indicator.iconFrame.maxY <= height)
            precondition(indicator.iconFrame.maxX < timeLabel.frame.minX, "The larger calendar must retain a gap before event text")
        }
        button.setFrameSize(NSSize(width: width, height: 24)); indicator.layout()
        let longTitle = String(repeating: "很长的日程名称 · long event 👩🏽‍💻 ", count: 100)
        let longEvent = CalendarMenuText(time: "Tomorrow 9:00 AM", title: longTitle)
        precondition(indicator.setEvent(longEvent) == 320)
        precondition(indicator.setEvent(longEvent, availableWidth: 120) == 120)
        precondition(button.toolTip?.contains(longTitle) == true)
        let compact = indicator.setEvent(longEvent, availableWidth: 60)
        precondition(compact == NSStatusBar.system.thickness)
        button.setFrameSize(NSSize(width: compact, height: 24)); indicator.layout()
        precondition(indicator.iconFrame.minX >= 0 && indicator.iconFrame.maxX <= compact)
        precondition(indicator.iconFrame.width == 18 && indicator.iconFrame.midX == compact / 2)
        precondition(indicator.contentView.subviews.compactMap { $0 as? NSTextField }.allSatisfy { $0.isHidden })
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let right = NSRect(x: 850, y: 950, width: 662, height: 32)
        let wide = StatusActivityIndicator.availableWidth(screenFrame: screen, topRightArea: nil, itemFrame: nil)
        let notched = StatusActivityIndicator.availableWidth(screenFrame: screen, topRightArea: right, itemFrame: nil)
        precondition(wide == 320 && notched == 320)
        precondition(StatusActivityIndicator.availableWidth(screenFrame: NSRect(x: 0, y: 0, width: 2560, height: 1440),
            topRightArea: nil, itemFrame: nil) == 320)
        let crowded = StatusActivityIndicator.availableWidth(screenFrame: screen, topRightArea: right,
            itemFrame: NSRect(x: 820, y: 950, width: 200, height: 24))
        precondition(crowded == 154)
        let hidden = StatusActivityIndicator.availableWidth(screenFrame: screen, topRightArea: right,
            itemFrame: NSRect(x: 550, y: 950, width: 200, height: 24))
        precondition(hidden == 320, "An item on the left side of the notch must use that side's space")
        precondition(indicator.setEvent(longEvent, availableWidth: hidden) == 320)
        let leftOfMiddle = StatusActivityIndicator.availableWidth(screenFrame: screen, topRightArea: nil,
            itemFrame: NSRect(x: 220, y: 950, width: 100, height: 24))
        precondition(leftOfMiddle == 304, "Real space before screen center must not collapse to icon-only")
        precondition(indicator.setEvent(sample, availableWidth: leftOfMiddle) > 80)
        let external = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        precondition(StatusActivityIndicator.availableWidth(screenFrame: external, topRightArea: nil,
            itemFrame: NSRect(x: -100, y: 1056, width: 100, height: 24)) == 320)
        _ = indicator.setEvent(nil)
        precondition(!button.toolTip!.contains(sample.title))
        if CommandLine.arguments.count > 1 {
            button.appearance = NSAppearance(named: .darkAqua)
            button.isBordered = false; button.title = ""
            indicator.iconView.image = NSImage(contentsOfFile: "Resources/status-icon.pdf") ?? original
            _ = indicator.setEvent(sample)
            button.setFrameSize(NSSize(width: 320, height: 32)); indicator.layout()
            indicator.iconView.layoutSubtreeIfNeeded()
            button.appearance!.performAsCurrentDrawingAppearance {
                let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
                button.cacheDisplay(in: button.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
            }
        }
        print("PASS: static 18-point calendar during activity, no timer redraws, two-line time/title, 22/24/32-point bars, width limits, icon fallback, full tooltip")
    }
}
