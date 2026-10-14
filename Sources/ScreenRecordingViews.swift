import AppKit
@preconcurrency import AVFoundation
import Combine
import SwiftUI

/// Inputs chosen for one recording. Every source starts off for each new recording.
@MainActor final class RecordingSetup: ObservableObject {
    struct Device: Identifiable, Hashable { let id: String; let name: String }
    @Published var microphones: [Device] = []
    @Published var cameras: [Device] = []
    @Published var microphone: String?
    @Published var camera: String?
    @Published var systemAudio = false
    func reset() {
        microphone = nil; camera = nil; systemAudio = false
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external], mediaType: .video, position: .unspecified)
            .devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }
}

private extension Image {
    func barSymbol() -> some View { font(.system(size: 18, weight: .regular)).frame(width: 30, height: 30).contentShape(Rectangle()) }
}

/// Choosing a device turns the source on; "None" turns it off.
private struct DevicePicker: View {
    var symbol: String
    var title: String
    var none: String
    var devices: [RecordingSetup.Device]
    @Binding var selection: String?
    var body: some View {
        let name = devices.first { $0.id == selection }?.name
        Menu {
            Toggle(none, isOn: Binding(get: { selection == nil }, set: { if $0 { selection = nil } }))
            if devices.isEmpty { Text("No \(title.lowercased()) found") } else { Divider() }
            ForEach(devices) { device in
                Toggle(device.name, isOn: Binding(get: { selection == device.id }, set: { selection = $0 ? device.id : nil }))
            }
        } label: {
            Image(systemName: selection == nil ? "\(symbol).slash" : symbol).barSymbol()
        }
        .menuStyle(.button).buttonStyle(HoverButtonStyle()).menuIndicator(.hidden).fixedSize()
        .help(name.map { "\(title): \($0)" } ?? "\(title): Off")
        .accessibilityLabel(name.map { "\(title), \($0)" } ?? "\(title), off")
    }
}

struct RecordingSetupBar: View {
    @ObservedObject var setup: RecordingSetup
    var start: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 14) {
                DevicePicker(symbol: "mic", title: "Microphone", none: "Don't Record Microphone", devices: setup.microphones, selection: $setup.microphone)
                DevicePicker(symbol: "video", title: "Camera", none: "No Camera", devices: setup.cameras, selection: $setup.camera)
                Button { setup.systemAudio.toggle() } label: {
                    Image(systemName: setup.systemAudio ? "speaker.wave.2" : "speaker.slash").barSymbol()
                }
                .buttonStyle(HoverButtonStyle())
                .help(setup.systemAudio ? "System audio: On" : "System audio: Off")
                .accessibilityLabel(setup.systemAudio ? "System audio, on" : "System audio, off")
            }
            Divider().frame(height: 20).padding(.horizontal, 16)
            Button(action: start) {
                HStack(spacing: 8) {
                    Image(systemName: "record.circle").font(.system(size: 20, weight: .regular))
                    Text("Start Recording").font(.system(size: 16, weight: .medium))
                }.padding(.horizontal, 8).frame(height: 32).contentShape(Capsule())
            }.buttonStyle(HoverButtonStyle()).keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 18).padding(.trailing, 14).frame(height: 50)
        .foregroundStyle(.primary)
        .inputGlass()
        .padding(18)
        .fixedSize()
    }
}

/// Shown in the middle of each display before anything is selected.
struct RecordingHint: View {
    var text: String
    var body: some View {
        Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).frame(height: 34).inputGlass().padding(18).fixedSize()
    }
}

@MainActor final class RecordingStopModel: ObservableObject {
    enum State: Equatable { case starting, recording(Date), saving, saved }
    @Published var state = State.starting
    var stop: () -> Void = {}
    weak var window: NSWindow?
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    /// Moves by the global pointer so the window's own motion never feeds back into the gesture.
    func drag() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (mouse, window.frame.origin) }
        guard let start = dragStart else { return }
        window.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }
    func endDrag() { dragStart = nil }
}

struct RecordingStopBar: View {
    @ObservedObject var model: RecordingStopModel
    /// On macOS 26 the panel hosts this inside AppKit's NSGlassEffectView.
    var nativeGlass = false
    var body: some View {
        if nativeGlass { content.fixedSize() } else { content.inputGlass().padding(18).fixedSize() }
    }
    private var content: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").font(.system(size: 16, weight: .regular)).foregroundStyle(.secondary)
                .frame(width: 22).help("Drag to move").accessibilityHidden(true)
            switch model.state {
            case .starting:
                ProgressView().controlSize(.small)
                Text("Starting…").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            case .recording(let start):
                Button(action: model.stop) {
                    HStack(spacing: 7) {
                        Image(systemName: "stop.circle").font(.system(size: 21, weight: .medium))
                        TimelineView(.periodic(from: start, by: 1)) { context in
                            Text(ScreenRecordingRules.elapsed(context.date.timeIntervalSince(start)))
                                .font(.system(size: 17, weight: .medium)).monospacedDigit()
                        }
                    }.foregroundStyle(.red).padding(.horizontal, 6).frame(height: 32).contentShape(Capsule())
                }.buttonStyle(HoverButtonStyle()).help("Stop Recording").accessibilityLabel("Stop Recording")
            case .saving:
                ProgressView().controlSize(.small)
                Text("Saving…").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            case .saved:
                Image(systemName: "checkmark.circle").font(.system(size: 19, weight: .medium)).foregroundStyle(.green)
                Text("Saved to Desktop · Copied").font(.system(size: 15, weight: .medium))
            }
        }
        .padding(.leading, 18).padding(.trailing, 14).frame(height: 50)
        .contentShape(Capsule())
        .gesture(DragGesture(minimumDistance: 1).onChanged { _ in model.drag() }.onEnded { _ in model.endDrag() })
    }
}

/// The stop bar's base: a native liquid-glass capsule with a soft drop shadow like the setup bar's SwiftUI glass.
/// The shadow is masked to fall only outside the capsule so it never darkens the translucent glass.
@available(macOS 26, *)
final class RecordingGlassView<Content: View>: NSView {
    static var margin: CGFloat { 20 }
    let host: NSHostingView<Content>
    private let glass = NSGlassEffectView()
    /// AppKit resets shadow properties on a view's own backing layer, so the shadows live on sublayers.
    private let shadowHost = NSView()
    /// A light, diffuse shadow matching the SwiftUI glass of the setup bar.
    private let shadows = [RecordingGlassView.shadowLayer(opacity: 0.12, radius: 9, offset: -3)]
    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        glass.style = .regular
        glass.contentView = host
        shadowHost.wantsLayer = true
        shadows.forEach { shadowHost.layer?.addSublayer($0) }
        addSubview(shadowHost)
        addSubview(glass)
    }
    required init?(coder: NSCoder) { nil }
    private static func shadowLayer(opacity: Float, radius: CGFloat, offset: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = opacity; layer.shadowRadius = radius; layer.shadowOffset = CGSize(width: 0, height: offset)
        return layer
    }
    /// Sizes the capsule to its content and returns the view size including the shadow margin.
    @discardableResult func fit() -> CGSize {
        let bar = host.fittingSize, margin = Self.margin
        let size = CGSize(width: bar.width + margin * 2, height: bar.height + margin * 2)
        setFrameSize(size)
        let capsuleFrame = NSRect(x: margin, y: margin, width: bar.width, height: bar.height)
        glass.frame = capsuleFrame; glass.cornerRadius = bar.height / 2
        host.frame = NSRect(origin: .zero, size: bar)
        shadowHost.frame = bounds
        let capsule = CGPath(roundedRect: capsuleFrame, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shadow in shadows { shadow.frame = bounds; shadow.shadowPath = capsule }
        // Only outside the capsule, so the translucent glass is never darkened from behind.
        let outside = CGMutablePath(); outside.addRect(bounds); outside.addPath(capsule)
        let mask = CAShapeLayer(); mask.path = outside; mask.fillRule = .evenOdd
        shadowHost.layer?.mask = mask
        CATransaction.commit()
        return size
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return glass.frame.contains(local) ? super.hitTest(point) : nil
    }
}

/// Floating stop control. Excluded from the capture so it never appears in the video.
final class RecordingStopPanel: NSPanel {
    let model = RecordingStopModel()
    private var fitContent: () -> CGSize = { .zero }
    private var stateWatch: AnyCancellable?
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        level = .statusBar; hidesOnDeactivate = false; isReleasedWhenClosed = false; animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        sharingType = .none
        title = "Telos Recording Controls"
        if #available(macOS 26, *) {
            let view = RecordingGlassView(rootView: RecordingStopBar(model: model, nativeGlass: true))
            contentView = view
            fitContent = { [unowned view] in view.fit() }
        } else {
            let host = NSHostingView(rootView: RecordingStopBar(model: model))
            contentView = host
            fitContent = { [unowned host] in host.fittingSize }
        }
        model.window = self
        // The bar changes width between recording, saving and saved; keep it centred where it is.
        stateWatch = model.$state.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.fit(keepingCenter: true) } }
    }
    override var canBecomeKey: Bool { false }
    func show(on screen: NSScreen) {
        fit(keepingCenter: false)
        let area = screen.visibleFrame
        setFrameOrigin(CGPoint(x: (area.midX - frame.width / 2).rounded(), y: area.minY + 12))
        orderFrontRegardless()
    }
    private func fit(keepingCenter: Bool) {
        let size = fitContent()
        let origin = keepingCenter ? CGPoint(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded()) : frame.origin
        setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// Mirrored, circular live camera preview. It appears as soon as a camera is chosen,
/// is recorded as part of the screen, and can be dragged anywhere.
@MainActor final class RecordingCameraBubble {
    let window: NSPanel
    private let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?
    private var placed: NSRect?
    private(set) var deviceID: String?
    init() {
        let side = 180 + CameraBubbleView.margin * 2
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // The system window shadow is heavy; the view draws a lighter one.
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
        // Above the selection overlay so it stays bright and draggable while choosing an area.
        window.level = .popUpMenu
        window.hidesOnDeactivate = false; window.isReleasedWhenClosed = false; window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.title = "Telos Camera"
        window.contentView = CameraBubbleView(frame: NSRect(x: 0, y: 0, width: side, height: side), session: session)
    }
    /// Switches the live feed to another camera without closing the bubble.
    func use(_ deviceID: String) -> Bool {
        guard deviceID != self.deviceID else { return true }
        guard let device = AVCaptureDevice(uniqueID: deviceID), let next = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        guard session.canAddInput(next) else {
            if let input, session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration(); return false
        }
        session.addInput(next); input = next; self.deviceID = deviceID
        session.commitConfiguration()
        (window.contentView as? CameraBubbleView)?.mirror()
        return true
    }
    /// Bottom-left of the area being recorded, until the user moves it.
    func place(in rect: CGRect) {
        guard placed == nil || placed == window.frame, !rect.isNull, !rect.isEmpty else { return }
        let side = window.frame.width, inset = 24 - CameraBubbleView.margin
        let frame = NSRect(x: rect.minX + inset, y: rect.minY + inset, width: side, height: side)
        window.setFrame(frame, display: true); placed = frame
    }
    func show() {
        window.orderFrontRegardless()
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { if !session.isRunning { session.startRunning() } }
    }
    func close() {
        window.orderOut(nil)
        let session = session
        DispatchQueue.global(qos: .utility).async { session.stopRunning() }
    }
}

private final class CameraBubbleView: NSView {
    /// Transparent room around the circle for its soft shadow.
    static let margin: CGFloat = 12
    private let preview: AVCaptureVideoPreviewLayer
    private var dragStart: (mouse: CGPoint, origin: CGPoint)?
    init(frame: NSRect, session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Clip the video itself: the window's root layer geometry is managed by AppKit.
        let circle = CGPath(ellipseIn: bounds.insetBy(dx: Self.margin, dy: Self.margin), transform: nil)
        let shadow = CAShapeLayer()
        shadow.path = circle; shadow.fillColor = NSColor.black.cgColor
        shadow.shadowPath = circle; shadow.shadowColor = NSColor.black.cgColor
        shadow.shadowOpacity = 0.16; shadow.shadowRadius = 6; shadow.shadowOffset = CGSize(width: 0, height: -2)
        let mask = CAShapeLayer(); mask.path = circle
        preview.videoGravity = .resizeAspectFill
        preview.frame = bounds; preview.backgroundColor = NSColor.black.cgColor
        preview.mask = mask
        layer?.addSublayer(shadow); layer?.addSublayer(preview)
        setAccessibilityLabel("Camera preview")
    }
    required init?(coder: NSCoder) { nil }
    /// Mirror like FaceTime; the connection exists only once a camera input is attached.
    func mirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (NSEvent.mouseLocation, window.frame.origin); NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window, let start = dragStart else { return }
        let mouse = NSEvent.mouseLocation
        window.setFrameOrigin(CGPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }
    override func mouseUp(with event: NSEvent) { if dragStart != nil { NSCursor.pop() }; dragStart = nil }
}
