import AppKit
import QuartzCore

/// Keep the static calendar's local image geometry independent of AppKit's host view.
final class StatusActivityImageView: NSView {
    let rotationLayer = CALayer()
    var image: NSImage? { didSet { renderedKey = nil; refreshImage() } }
    private var renderedKey: String?
    private var refreshQueued = false
    private(set) var rasterizationCount = 0
    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        // Menu-bar snapshots temporarily change appearance. Mutating a layer inside
        // that callback requests another snapshot and can keep the main thread busy.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refreshImage()
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(rotationLayer)
        rotationLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rotationLayer.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        let targetBounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        let targetPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        guard rotationLayer.bounds != targetBounds || rotationLayer.position != targetPosition else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rotationLayer.bounds = targetBounds
        rotationLayer.position = targetPosition
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshImage(); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); scheduleRefresh() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshImage() }
    private func refreshImage() {
        guard let image else { rotationLayer.contents = nil; return }
        let scale = window?.backingScaleFactor ?? 2
        let key = "\(effectiveAppearance.name.rawValue):\(scale)"
        guard renderedKey != key else { return }
        renderedKey = key
        let pixels = Int(StatusCalendarIcon.side * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            let rect = NSRect(x: 0, y: 0, width: StatusCalendarIcon.side, height: StatusCalendarIcon.side)
            image.draw(in: StatusCalendarIcon.fittedRect(for: image, in: rect))
            NSColor.labelColor.setFill(); rect.fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rasterizationCount += 1
        rotationLayer.contentsScale = scale; rotationLayer.contents = bitmap.cgImage
        CATransaction.commit()
    }
}

private final class StatusEventMarker: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 1, yRadius: 1).fill()
    }
    private var appearanceName: NSAppearance.Name?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.appearanceName != self.effectiveAppearance.name else { return }
            self.appearanceName = self.effectiveAppearance.name
            self.needsDisplay = true
        }
    }
}
private final class StatusEventLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The icon has a fixed local coordinate space, independent of the event label's width.
@MainActor final class StatusActivityIndicator {
    static let animationKey = "telos.taskActivity"
    nonisolated static let maximumEventWidth: CGFloat = 320
    // Leave room for the camera housing/app menus and the other status items.
    static func availableWidth(screenFrame: NSRect, topRightArea: NSRect?, itemFrame: NSRect?) -> CGFloat {
        // Status items may be reordered onto either side of the camera housing.
        // Do not reserve an imaginary 45% of unnotched displays for app menus.
        // AppKit manages competition with other apps' menu items.
        let onLeftOfNotch = topRightArea.map { area in itemFrame.map { $0.maxX <= area.minX } ?? false } ?? false
        let safeLeft = onLeftOfNotch ? screenFrame.minX : (topRightArea?.minX ?? screenFrame.minX)
        let segmentWidth = screenFrame.maxX - safeLeft
        var available = min(maximumEventWidth, segmentWidth - 16)
        if let itemFrame {
            available = min(available, itemFrame.maxX - safeLeft - 16)
        }
        return max(0, floor(available))
    }
    static func eventWidth(textWidth: CGFloat, availableWidth: CGFloat, thickness: CGFloat) -> CGFloat {
        let cap = min(maximumEventWidth, availableWidth)
        // A tiny clipped label is less useful than a clearly visible icon.
        guard cap >= 80 else { return thickness }
        // Short titles such as “调休” still need to meet layout's label threshold.
        return min(cap, max(80, ceil(textWidth) + 45))
    }
    private weak var button: NSButton?
    let iconView = StatusActivityImageView()
    let contentView = NSView()
    private var renderedImageKey = ""
    private(set) var renderedImageCount = 0
    private let marker = StatusEventMarker()
    private let timeLabel = StatusEventLabel(labelWithString: "")
    private let eventLabel = StatusEventLabel(labelWithString: "")
    private var count = 0
    private var event: CalendarMenuText?
    private(set) var currentSymbolName = ""
    var iconFrame: NSRect { iconView.frame }

    init(button: NSButton) {
        self.button = button
        button.image = nil
        contentView.addSubview(iconView)
        iconView.setAccessibilityElement(false)
        timeLabel.font = .systemFont(ofSize: 9, weight: .regular)
        eventLabel.font = .systemFont(ofSize: 11, weight: .regular)
        for label in [timeLabel, eventLabel] {
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            contentView.addSubview(label)
        }
        contentView.addSubview(marker)
        marker.setAccessibilityElement(false)
        updateDate()
        layout()
    }
    func updateDate(_ date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) {
        let name = StatusCalendarIcon.symbolName(for: date, timeZone: timeZone)
        guard name != currentSymbolName else { return }
        currentSymbolName = name
        iconView.image = StatusCalendarIcon.image(for: date, timeZone: timeZone)
        renderButtonImage()
    }
    static func runningCount(_ tasks: [Todo]) -> Int { tasks.filter { $0.status == "running" }.count }
    func setEvent(_ event: CalendarMenuText?, availableWidth: CGFloat = maximumEventWidth) -> CGFloat {
        self.event = event
        timeLabel.stringValue = event?.time ?? ""
        eventLabel.stringValue = event?.title ?? ""
        // NSTextField includes its text-cell insets and fallback fonts in this measurement.
        let textWidth = max(timeLabel.intrinsicContentSize.width, eventLabel.intrinsicContentSize.width)
        let width: CGFloat = event == nil ? NSStatusBar.system.thickness
            : Self.eventWidth(textWidth: textWidth, availableWidth: availableWidth, thickness: NSStatusBar.system.thickness)
        layout(width: width)
        updateAccessibility()
        return width
    }
    func layout(width: CGFloat? = nil) {
        guard let button else { return }
        let width = width ?? button.bounds.width
        let showTitle = event != nil && width >= 80
        let side = StatusCalendarIcon.side
        iconView.frame = NSRect(x: showTitle ? 13 - side / 2 : (width - side) / 2,
                               y: (button.bounds.height - side) / 2, width: side, height: side)
        iconView.needsLayout = true
        marker.frame = NSRect(x: 28, y: (button.bounds.height - 9) / 2, width: 2, height: 9)
        marker.isHidden = !showTitle
        let scale = min(1, button.bounds.height / 24)
        let bottom = (button.bounds.height - 24 * scale) / 2
        timeLabel.font = .systemFont(ofSize: 9 * scale, weight: .regular)
        eventLabel.font = .systemFont(ofSize: 11 * scale, weight: .regular)
        let timeY = button.isFlipped ? bottom : bottom + 13 * scale
        let titleY = button.isFlipped ? bottom + 11 * scale : bottom
        eventLabel.frame = NSRect(x: 35, y: titleY, width: max(0, width - 41), height: 13 * scale)
        timeLabel.frame = NSRect(x: 35, y: timeY, width: max(0, width - 41), height: 11 * scale)
        timeLabel.isHidden = !showTitle; eventLabel.isHidden = !showTitle
        contentView.setFrameSize(NSSize(width: width, height: button.bounds.height))
        renderButtonImage()
    }
    private func renderButtonImage() {
        guard let button, let source = iconView.image else { return }
        let size = contentView.frame.size
        guard size.width > 0, size.height > 0 else { return }
        let key = "\(currentSymbolName):\(size):\(event?.time ?? ""):\(event?.title ?? "")"
        guard renderedImageKey != key else { return }
        renderedImageKey = key
        // Native status-button template images avoid AppKit recursively snapshotting
        // appearance-changing subviews. Rebuild only when calendar content or size changes.
        let image = NSImage(size: size)
        image.lockFocus()
        source.draw(in: StatusCalendarIcon.fittedRect(for: source, in: iconView.frame))
        if !marker.isHidden {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: marker.frame, xRadius: 1, yRadius: 1).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            for label in [timeLabel, eventLabel] {
                var rect = label.frame
                if button.isFlipped { rect.origin.y = size.height - rect.maxY }
                (label.stringValue as NSString).draw(in: rect, withAttributes: [.font: label.font!, .foregroundColor: NSColor.black, .paragraphStyle: paragraph])
            }
        }
        image.unlockFocus()
        image.isTemplate = true
        renderedImageCount += 1
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.image = image
    }
    private func updateAccessibility() {
        let activity = count > 0 ? " — \(count) tasks running" : ""
        let text = "Pico" + activity + (event.map { " — " + $0.time + " · " + $0.title } ?? "")
        button?.toolTip = text; button?.setAccessibilityLabel(text)
    }
    func update(count: Int, reduceMotion _: Bool) {
        self.count = count
        updateAccessibility()
        layout()
        // Activity stays visible in the tooltip, while the calendar remains upright.
        // No activity timer or bitmap rotation runs during tasks or meetings.
        let layer = iconView.rotationLayer
        layer.removeAnimation(forKey: Self.animationKey)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }
}
