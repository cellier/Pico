import AppKit

/// Keep the menu-bar button momentary, independently of the main window.
@MainActor final class StatusButtonFeedback: NSObject {
    private weak var button: NSButton?
    private var area: NSTrackingArea?
    private var refreshID = 0
    private var stopped = false
    private(set) var isHovered = false

    init(button: NSButton) {
        self.button = button
        super.init()
        if let cell = button.cell as? NSButtonCell {
            cell.showsStateBy = []
            cell.highlightsBy = [.changeBackgroundCellMask]
        }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
            owner: self, userInfo: nil)
        self.area = area
        button.addTrackingArea(area)
        syncAfterTracking()
    }

    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) { applyHover(true) }
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { applyHover(false) }

    func syncAfterTracking() {
        guard !stopped else { return }
        applyHover(isHovered)
        refreshID += 1
        let token = refreshID
        // AppKit clears its press highlight after sending mouseUp/action. Restore
        // only actual hover, including after a context menu has finished tracking.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.refreshID == token else { return }
            guard let button = self.button, let window = button.window, window.isVisible else {
                self.applyHover(false); return
            }
            let point = button.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            self.applyHover(!button.isHidden && button.bounds.contains(point)
                && button.visibleRect.contains(point))
        }
    }

    private func applyHover(_ hovered: Bool) {
        guard !stopped else { return }
        isHovered = hovered
        button?.state = .off
        button?.highlight(hovered)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; refreshID += 1; isHovered = false
        if let area { button?.removeTrackingArea(area); self.area = nil }
        button?.state = .off; button?.highlight(false)
    }

    isolated deinit { if let area { button?.removeTrackingArea(area) } }
}
