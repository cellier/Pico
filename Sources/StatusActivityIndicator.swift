import AppKit
import QuartzCore

/// AppKit owns the view's backing-layer geometry. Rotate a separate local layer instead.
final class StatusActivityImageView: NSView {
    let rotationLayer = CALayer()
    var image: NSImage? { didSet { refreshImage() } }
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
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rotationLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        rotationLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshImage(); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshImage() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); refreshImage() }
    private func refreshImage() {
        guard let image else { rotationLayer.contents = nil; return }
        let scale = window?.backingScaleFactor ?? 2
        let pixels = Int(18 * scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            let rect = NSRect(x: 0, y: 0, width: 18, height: 18)
            image.draw(in: rect)
            NSColor.labelColor.setFill(); rect.fill(using: .sourceIn)
            NSGraphicsContext.restoreGraphicsState()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
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
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
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
    private let marker = StatusEventMarker()
    private let timeLabel = StatusEventLabel(labelWithString: "")
    private let eventLabel = StatusEventLabel(labelWithString: "")
    private var count = 0
    private var event: CalendarMenuText?
    var iconFrame: NSRect { iconView.frame }

    init(button: NSButton) {
        self.button = button
        iconView.image = button.image
        button.image = nil
        button.addSubview(iconView)
        iconView.setAccessibilityElement(false)
        timeLabel.font = .systemFont(ofSize: 9, weight: .regular)
        eventLabel.font = .systemFont(ofSize: 11, weight: .regular)
        for label in [timeLabel, eventLabel] {
            label.textColor = .labelColor
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.setAccessibilityElement(false)
            button.addSubview(label)
        }
        button.addSubview(marker)
        marker.setAccessibilityElement(false)
        layout()
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
        iconView.frame = NSRect(x: showTitle ? 5 : (width - 16) / 2, y: (button.bounds.height - 16) / 2, width: 16, height: 16)
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
    }
    private func updateAccessibility() {
        let activity = count > 0 ? " — \(count) tasks running" : ""
        let text = "Telos" + activity + (event.map { " — " + $0.time + " · " + $0.title } ?? "")
        button?.toolTip = text; button?.setAccessibilityLabel(text)
    }
    func update(count: Int, reduceMotion: Bool) {
        self.count = count
        updateAccessibility()
        layout()
        let layer = iconView.rotationLayer
        if count == 0 || reduceMotion {
            layer.removeAnimation(forKey: Self.animationKey)
        } else if layer.animation(forKey: Self.animationKey) == nil {
            let turn = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            // This NSView uses AppKit's unflipped coordinates: negative angles turn clockwise.
            turn.values = [0, -Double.pi * 2, -Double.pi * 2]
            turn.keyTimes = [0, 0.8, 1]
            // One uninterrupted revolution: accelerate, coast to rest, then pause for 0.5 s.
            turn.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.28, 0, 0.12, 1),
                CAMediaTimingFunction(name: .linear)
            ]
            turn.duration = 2.5; turn.repeatCount = .infinity
            layer.add(turn, forKey: Self.animationKey)
        }
    }
}
