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
    private weak var button: NSButton?
    let iconView = StatusActivityImageView()
    private let marker = StatusEventMarker()
    private let eventLabel = StatusEventLabel(labelWithString: "")
    private var count = 0
    private var eventTitle: String?
    var iconFrame: NSRect { iconView.frame }

    init(button: NSButton) {
        self.button = button
        iconView.image = button.image
        button.image = nil
        button.addSubview(iconView)
        iconView.setAccessibilityElement(false)
        eventLabel.font = .systemFont(ofSize: 13, weight: .regular)
        eventLabel.textColor = .labelColor
        eventLabel.lineBreakMode = .byTruncatingTail
        eventLabel.maximumNumberOfLines = 1
        eventLabel.setAccessibilityElement(false)
        button.addSubview(eventLabel)
        button.addSubview(marker)
        marker.setAccessibilityElement(false)
        layout()
    }
    static func runningCount(_ tasks: [Todo]) -> Int { tasks.filter { $0.status == "running" }.count }
    func setEvent(_ title: String?) -> CGFloat {
        eventTitle = title
        eventLabel.stringValue = title ?? ""
        // NSTextField includes its text-cell insets and fallback fonts in this measurement.
        let textWidth = eventLabel.intrinsicContentSize.width
        let width: CGFloat = title == nil ? NSStatusBar.system.thickness : min(480, ceil(textWidth) + 45)
        layout(width: width)
        updateAccessibility()
        return width
    }
    func layout(width: CGFloat? = nil) {
        guard let button else { return }
        let width = width ?? button.bounds.width
        iconView.frame = NSRect(x: eventTitle == nil ? (width - 16) / 2 : 5, y: (button.bounds.height - 16) / 2, width: 16, height: 16)
        iconView.needsLayout = true
        marker.frame = NSRect(x: 28, y: (button.bounds.height - 9) / 2, width: 2, height: 9)
        marker.isHidden = eventTitle == nil
        eventLabel.frame = NSRect(x: 35, y: (button.bounds.height - 18) / 2, width: max(0, width - 41), height: 18)
        eventLabel.isHidden = eventTitle == nil
    }
    private func updateAccessibility() {
        let activity = count > 0 ? " — \(count) tasks running" : ""
        let text = "Telos" + activity + (eventTitle.map { " — " + $0 } ?? "")
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
