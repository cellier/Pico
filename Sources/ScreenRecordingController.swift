import AppKit
import AVFoundation
import Carbon
import Combine
import ScreenCaptureKit
import SwiftUI

struct RecordingTarget: Equatable {
    enum Kind: Equatable { case screen, area, window(CGWindowID) }
    var kind: Kind
    /// AppKit global points.
    var frame: CGRect
    var displayID: CGDirectDisplayID
}

struct PickableWindow: Equatable { let id: CGWindowID; let frame: CGRect }

extension NSScreen {
    var recordingDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

private struct RecordingFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Option+R: click records a whole display, Space then click records a window, dragging records an area.
/// Escape cancels selection. The stop bar is excluded from the video; the MP4 is saved to the Desktop and copied.
@MainActor final class ScreenRecordingController {
    private enum Phase { case idle, selecting, starting, recording, finishing }
    private var phase = Phase.idle
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var prepare: () -> Void = {}
    var failed: (String) -> Void = { _ in }
    var isSelecting: Bool { phase == .selecting }

    fileprivate let setup = RecordingSetup()
    private var overlays: [RecordingOverlayWindow] = []
    private var bar: NSView?
    private var keyMonitor: Any?
    private var homeScreen: NSScreen?
    private var pickable: [PickableWindow] = []
    private(set) var selection: RecordingTarget?
    private(set) var windowMode = false
    private(set) var hovered: PickableWindow?
    private(set) var dragRect: CGRect?

    private var recorder: AnyObject?
    private var stopPanel: RecordingStopPanel?
    fileprivate var camera: RecordingCameraBubble?
    private var cameraWatch: AnyCancellable?
    private var notice: String?
    private var startedAt = Date()
    private var finishing: Task<Void, Never>?

    // MARK: Shortcut

    func register() -> OSStatus {
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &identifier)
                guard result == noErr, identifier.signature == 0x544C5352, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<ScreenRecordingController>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { controller.shortcutPressed() }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard installed == noErr else { return installed }
        }
        return registerKey()
    }
    private func registerKey() -> OSStatus {
        guard hotKey == nil else { return noErr }
        return RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(optionKey), EventHotKeyID(signature: 0x544C5352, id: 1),
                                   GetApplicationEventTarget(), 0, &hotKey)
    }
    private func shortcutPressed() {
        if phase != .selecting, Self.textInputHasFocus() { typeThrough(); return }
        switch phase {
        case .idle: start()
        case .recording: stop()
        default: break
        }
    }
    /// Hand Option+R back to the focused text field so the active keyboard layout types its character (® on US).
    private func typeThrough() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_R), keyDown: down) else { continue }
            event.flags = .maskAlternate
            event.post(tap: .cgSessionEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in _ = self?.registerKey() }
    }
    static func textInputHasFocus() -> Bool {
        if NSApp.isActive, let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable { return true }
        guard AXIsProcessTrusted() else { return false }
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        guard let raw = attribute(system, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        var element = raw as! AXUIElement
        // Rich editors can focus an inner node whose editable ancestor owns the caret.
        for _ in 0..<5 {
            if ScreenRecordingRules.acceptsTyping(role: attribute(element, kAXRoleAttribute) as? String ?? "",
                                                  editable: attribute(element, "AXEditable") as? Bool,
                                                  enabled: attribute(element, kAXEnabledAttribute) as? Bool) { return true }
            guard let parent = attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            element = parent as! AXUIElement
        }
        return false
    }

    // MARK: Selection

    func start() {
        guard phase == .idle else { return }
        guard #available(macOS 15, *) else { failed("Screen recording requires macOS 15 or later."); return }
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            failed("Allow Screen Recording for Telos in System Settings, then press Option+R again.")
            return
        }
        prepare()
        phase = .selecting
        setup.reset()
        selection = nil; windowMode = false; hovered = nil; dragRect = nil; notice = nil
        cameraWatch = setup.$camera.dropFirst().removeDuplicates().sink { [weak self] id in self?.cameraChosen(id) }
        homeScreen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        overlays = NSScreen.screens.map { RecordingOverlayWindow(screen: $0, controller: self) }
        let host = NSHostingView(rootView: RecordingSetupBar(setup: setup) { [weak self] in self?.startRecording() })
        host.setFrameSize(host.fittingSize)
        bar = host
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window is RecordingOverlayWindow else { return event }
            return self.handleKey(event) ? nil : event
        }
        NSApp.activate(ignoringOtherApps: true)
        overlays.forEach { $0.orderFrontRegardless() }
        (overlays.first { $0.targetScreen == homeScreen } ?? overlays.first)?.makeKey()
        refresh()
    }
    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape: cancel()
        case kVK_Space: toggleWindowMode()
        case kVK_Return, kVK_ANSI_KeypadEnter: startRecording()
        default: return false
        }
        return true
    }
    func cancel() {
        guard phase == .selecting else { return }
        closeOverlays(); phase = .idle
        camera?.close(); camera = nil
    }
    private func closeOverlays() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil; cameraWatch = nil
        bar?.removeFromSuperview(); bar = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
    }
    fileprivate func toggleWindowMode() {
        windowMode.toggle()
        pickable = windowMode ? Self.pickableWindows() : []
        hovered = windowMode ? pickable.first { $0.frame.contains(NSEvent.mouseLocation) } : nil
        refresh()
    }
    /// The rectangle left undimmed on every display.
    var highlight: CGRect? { dragRect ?? (windowMode ? hovered?.frame : selection?.frame) }
    var hint: String? {
        guard dragRect == nil else { return nil }
        if let notice { return notice }
        if windowMode { return hovered == nil ? "Click a window to record it · Space for area · Esc to cancel" : nil }
        return selection == nil ? "Click to record this screen · Drag to select an area · Space to pick a window · Esc to cancel" : nil
    }

    fileprivate func hover(at point: CGPoint) {
        guard windowMode else { return }
        let next = pickable.first { $0.frame.contains(point) }
        if next != hovered { hovered = next; refresh() }
    }
    fileprivate func drag(from start: CGPoint, to end: CGPoint, on screen: NSScreen) {
        windowMode = false; hovered = nil
        dragRect = ScreenRecordingRules.dragRect(from: start, to: end, within: screen.frame)
        refresh()
    }
    fileprivate func endDrag(on screen: NSScreen) {
        notice = nil
        if let rect = dragRect, ScreenRecordingRules.isUsableArea(rect) {
            selection = RecordingTarget(kind: .area, frame: rect.integral, displayID: screen.recordingDisplayID)
        }
        dragRect = nil; refresh()
    }
    fileprivate func click(at point: CGPoint, on screen: NSScreen) {
        notice = nil
        if windowMode {
            guard let window = pickable.first(where: { $0.frame.contains(point) }) else { return }
            let display = NSScreen.screens.max { $0.frame.intersection(window.frame).area < $1.frame.intersection(window.frame).area } ?? screen
            selection = RecordingTarget(kind: .window(window.id), frame: window.frame.intersection(display.frame), displayID: display.recordingDisplayID)
            windowMode = false; hovered = nil
        } else {
            selection = RecordingTarget(kind: .screen, frame: screen.frame, displayID: screen.recordingDisplayID)
        }
        refresh()
    }
    private func refresh() {
        overlays.forEach { $0.update(hint: hint) }
        camera?.place(in: cameraArea)
        guard let bar else { return }
        let screen = selection.flatMap { target in NSScreen.screens.first { $0.recordingDisplayID == target.displayID } } ?? homeScreen
        guard let screen, let content = overlays.first(where: { $0.targetScreen == screen })?.contentView else { return }
        if bar.superview !== content { bar.removeFromSuperview(); content.addSubview(bar) }
        // Before a selection the bar rests at the bottom; afterwards it sits in the middle of the selection.
        let size = bar.frame.size
        let anchor = selection?.frame ?? CGRect(x: screen.frame.minX, y: screen.visibleFrame.minY + 24, width: screen.frame.width, height: size.height)
        let origin = ScreenRecordingRules.barOrigin(size: size, centeredIn: anchor, screen: screen.frame)
        bar.setFrameOrigin(CGPoint(x: origin.x - screen.frame.minX, y: origin.y - screen.frame.minY))
        bar.isHidden = dragRect != nil || windowMode
    }
    /// Where the camera bubble starts: inside the visible part of the area that will be recorded.
    private var cameraArea: CGRect {
        let screen = selection.flatMap { target in NSScreen.screens.first { $0.recordingDisplayID == target.displayID } } ?? homeScreen
        guard let screen else { return .null }
        return (selection?.frame ?? screen.frame).intersection(screen.visibleFrame)
    }
    /// Choosing a camera shows its live bubble right away; "No Camera" removes it.
    private func cameraChosen(_ id: String?) {
        guard phase == .selecting else { return }
        guard let id else { camera?.close(); camera = nil; return }
        Task {
            let allowed = await Self.access(.video)
            guard phase == .selecting, setup.camera == id else { return }
            guard allowed else {
                setup.camera = nil
                notice = "Allow Camera for Telos in System Settings › Privacy & Security › Camera"
                refresh(); return
            }
            let bubble = camera ?? RecordingCameraBubble()
            guard bubble.use(id) else {
                setup.camera = nil; notice = "That camera is unavailable. Choose another one."
                refresh(); return
            }
            if camera == nil { camera = bubble; bubble.place(in: cameraArea); bubble.show() }
            NSApp.activate(ignoringOtherApps: true)
            overlays.first { $0.targetScreen == homeScreen }?.makeKey()
        }
    }
    static func pickableWindows() -> [PickableWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let own = ProcessInfo.processInfo.processIdentifier
        // Front-to-back order, so the first hit is the visible window.
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) != own,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds), rect.width >= 40, rect.height >= 40 else { return nil }
            return PickableWindow(id: CGWindowID(id), frame: ScreenRecordingRules.appKitRect(windowBounds: rect, primaryHeight: primary))
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard phase == .selecting, let screen = homeScreen ?? NSScreen.main else { return }
        let target = selection ?? RecordingTarget(kind: .screen, frame: screen.frame, displayID: screen.recordingDisplayID)
        let microphone = setup.microphone, cameraID = setup.camera, systemAudio = setup.systemAudio
        closeOverlays()
        phase = .starting
        guard #available(macOS 15, *) else { phase = .idle; return }
        Task { await launch(target, microphone: microphone, cameraID: cameraID, systemAudio: systemAudio) }
    }

    @available(macOS 15, *)
    private func launch(_ target: RecordingTarget, microphone: String?, cameraID: String?, systemAudio: Bool) async {
        do {
            if microphone != nil, !(await Self.access(.audio)) {
                throw RecordingFailure(message: "Allow Microphone for Telos in System Settings, or record with the microphone off.")
            }
            if cameraID != nil, camera == nil {
                throw RecordingFailure(message: "The camera preview could not start. Allow Camera for Telos in System Settings, or record with the camera off.")
            }
            guard let screen = NSScreen.screens.first(where: { $0.recordingDisplayID == target.displayID }) else {
                throw RecordingFailure(message: "The selected display is no longer connected.")
            }
            let panel = RecordingStopPanel()
            panel.model.stop = { [weak self] in self?.stop() }
            panel.show(on: screen)
            stopPanel = panel
            // Let the window server publish both windows so ScreenCaptureKit can exclude or include them.
            try await Task.sleep(nanoseconds: 150_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
                throw RecordingFailure(message: "The selected display is unavailable for recording.")
            }
            func shareable(_ window: NSWindow?) -> SCWindow? {
                guard let window else { return nil }
                return content.windows.first { $0.windowID == CGWindowID(window.windowNumber) }
            }
            let filter: SCContentFilter
            if case .window(let id) = target.kind {
                guard let window = content.windows.first(where: { $0.windowID == id }) else {
                    throw RecordingFailure(message: "The selected window closed before recording started.")
                }
                filter = SCContentFilter(display: display, including: [window] + [shareable(camera?.window)].compactMap { $0 })
            } else {
                filter = SCContentFilter(display: display, excludingWindows: [shareable(panel)].compactMap { $0 })
            }
            let config = SCStreamConfiguration()
            let source = ScreenRecordingRules.sourceRect(target.frame, screenFrame: screen.frame)
            config.sourceRect = source
            config.width = ScreenRecordingRules.pixels(source.width, scale: screen.backingScaleFactor)
            config.height = ScreenRecordingRules.pixels(source.height, scale: screen.backingScaleFactor)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.showsCursor = true
            config.capturesAudio = systemAudio
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000; config.channelCount = 2
            config.captureMicrophone = microphone != nil
            config.microphoneCaptureDeviceID = microphone
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("TelosRecording-\(UUID().uuidString).mp4")
            let recorder = ScreenRecorder(url: url)
            recorder.interrupted = { [weak self] in self?.stop() }
            try await recorder.start(filter: filter, configuration: config)
            self.recorder = recorder
            startedAt = Date()
            phase = .recording
            panel.model.state = .recording(startedAt)
        } catch {
            tearDownRecording()
            phase = .idle
            failed(error is RecordingFailure ? error.localizedDescription
                   : "Could not start screen recording: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard phase == .recording, #available(macOS 15, *), let recorder = recorder as? ScreenRecorder else { return }
        phase = .finishing
        stopPanel?.model.state = .saving
        finishing = Task {
            let error = await recorder.stop()
            self.recorder = nil
            camera?.close(); camera = nil
            do {
                _ = try Self.deliver(recorder.url, startedAt: startedAt, error: error)
                stopPanel?.model.state = .saved
                try? await Task.sleep(nanoseconds: 1_400_000_000)
            } catch {
                failed(error.localizedDescription)
            }
            tearDownRecording()
            phase = .idle
            finishing = nil
        }
    }
    /// Quitting mid-recording still saves what was captured.
    func finishBeforeQuit() async {
        if phase == .selecting { cancel() }
        if phase == .recording { stop() }
        await finishing?.value
    }
    private func tearDownRecording() {
        camera?.close(); camera = nil
        stopPanel?.orderOut(nil); stopPanel = nil
        recorder = nil
    }
    private static func access(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }
    /// Move the finished movie to the Desktop, named by its start time, and put the file on the clipboard.
    static func deliver(_ temporary: URL, startedAt: Date, error: Error?) throws -> URL {
        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw RecordingFailure(message: "The recording could not be finished\(error.map { ": \($0.localizedDescription)" } ?? ".")")
        }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let destination = ScreenRecordingRules.availableURL(named: ScreenRecordingRules.fileName(startedAt: startedAt), in: desktop)
        do { try FileManager.default.moveItem(at: temporary, to: destination) }
        catch { throw RecordingFailure(message: "Could not save the recording to the Desktop. It remains at \(temporary.path).") }
        if !copyRecording(destination) { throw RecordingFailure(message: "Saved \(destination.lastPathComponent) to the Desktop, but could not copy it.") }
        return destination
    }
    @discardableResult
    static func copyRecording(_ url: URL, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([url as NSURL])
    }

    func shutdown() {
        cancel()
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// One ScreenCaptureKit stream writing straight to an MP4.
@available(macOS 15, *)
@MainActor final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    let url: URL
    var interrupted: () -> Void = {}
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var done = false
    private var doneError: Error?
    private var waiters: [CheckedContinuation<Error?, Never>] = []
    init(url: URL) { self.url = url }

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws {
        let settings = SCRecordingOutputConfiguration()
        settings.outputURL = url
        settings.outputFileType = .mp4
        settings.videoCodecType = .h264
        let output = SCRecordingOutput(configuration: settings, delegate: self)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
        try await stream.startCapture()
        self.stream = stream; self.output = output
    }
    /// Stops capture and waits for the movie to be finalized.
    func stop() async -> Error? {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        if done { return doneError }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.finish(nil) }
        }
    }
    private func finish(_ error: Error?) {
        guard !done else { return }
        done = true; doneError = error
        waiters.forEach { $0.resume(returning: error) }
        waiters = []
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.finish(nil) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.finish(error) }
    }
    /// The user can end capture from the system's screen-sharing menu; save what was recorded.
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.interrupted() }
    }
}

// MARK: Overlay

final class RecordingOverlayWindow: NSWindow {
    let targetScreen: NSScreen
    private let overlay: RecordingOverlayView
    private let hintHost = PassthroughHostingView(rootView: RecordingHint(text: ""))
    init(screen: NSScreen, controller: ScreenRecordingController) {
        targetScreen = screen
        overlay = RecordingOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), screen: screen, controller: controller)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = false
        // Above the menu bar and Dock, below the pop-up menus the setup bar opens.
        level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false; animationBehavior = .none; acceptsMouseMovedEvents = true
        title = "Telos Recording Selection"
        contentView = overlay
        overlay.addSubview(hintHost)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    func update(hint: String?) {
        overlay.needsDisplay = true
        hintHost.isHidden = hint == nil
        guard let hint else { return }
        hintHost.rootView = RecordingHint(text: hint)
        let size = hintHost.fittingSize
        hintHost.frame = NSRect(x: ((overlay.bounds.width - size.width) / 2).rounded(), y: ((overlay.bounds.height - size.height) / 2).rounded(),
                                width: size.width, height: size.height)
    }
}

private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class RecordingOverlayView: NSView {
    private let screen: NSScreen
    private weak var controller: ScreenRecordingController?
    private var pressed: CGPoint?
    private var dragging = false
    init(frame: NSRect, screen: NSScreen, controller: ScreenRecordingController) {
        self.screen = screen; self.controller = controller
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseMoved(with event: NSEvent) { controller?.hover(at: NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) {
        pressed = NSEvent.mouseLocation; dragging = false
        if window?.isKeyWindow == false { window?.makeKey() }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let point = NSEvent.mouseLocation
        if dragging || ScreenRecordingRules.isDrag(from: pressed, to: point) {
            dragging = true
            controller?.drag(from: pressed, to: point, on: screen)
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil; dragging = false }
        guard pressed != nil else { return }
        if dragging { controller?.endDrag(on: screen) } else { controller?.click(at: NSEvent.mouseLocation, on: screen) }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let controller else { return }
        let local = controller.highlight.map { $0.intersection(screen.frame) }
            .flatMap { $0.isNull || $0.isEmpty ? nil : $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        let dim = NSBezierPath(rect: bounds)
        if let local { dim.append(NSBezierPath(rect: local)); dim.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.3).setFill()
        dim.fill()
        guard let local else { return }
        if controller.windowMode {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(rect: local).fill()
        }
        let border = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        NSColor.controlAccentColor.setStroke()
        border.stroke()
        if controller.dragRect != nil {
            let scale = screen.backingScaleFactor
            let label = "\(Int(local.width * scale)) × \(Int(local.height * scale))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let size = label.size(withAttributes: attributes)
            let below = local.minY - size.height - 8 > 0
            let box = NSRect(x: local.minX, y: below ? local.minY - size.height - 10 : local.minY + 6, width: size.width + 12, height: size.height + 4)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            label.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 2), withAttributes: attributes)
        }
    }
}

#if TELOS_DIAGNOSTICS
/// Records two seconds with the stop bar inside the captured area, then reports tracks and a frame for inspection.
enum ScreenRecordingDiagnostics {
    @MainActor static func run(output: URL) async {
        var report: [String: Any] = ["screen_access": CGPreflightScreenCaptureAccess()]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output) }
            NSApp.terminate(nil)
        }
        guard #available(macOS 15, *), let screen = NSScreen.main else { report["error"] = "unsupported"; return }
        let panel = RecordingStopPanel()
        panel.show(on: screen); panel.model.state = .recording(Date())
        let area = ProcessInfo.processInfo.environment["TELOS_RECORDING_FULL"] != nil ? screen.frame
            : CGRect(x: panel.frame.midX - 400, y: panel.frame.minY - 20, width: 800, height: 300).intersection(screen.frame)
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == screen.recordingDisplayID }) else { report["error"] = "display"; return }
            let excluded = content.windows.filter { $0.windowID == CGWindowID(panel.windowNumber) }
            report["stop_bar_shareable"] = excluded.count
            let config = SCStreamConfiguration()
            let source = ScreenRecordingRules.sourceRect(area, screenFrame: screen.frame)
            config.sourceRect = source
            config.width = ScreenRecordingRules.pixels(source.width, scale: screen.backingScaleFactor)
            config.height = ScreenRecordingRules.pixels(source.height, scale: screen.backingScaleFactor)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.capturesAudio = true; config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000; config.channelCount = 2
            if ProcessInfo.processInfo.environment["TELOS_RECORDING_MIC"] != nil {
                config.captureMicrophone = true
                config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
            }
            report["items_before"] = telosStatusItems()
            var bubble: RecordingCameraBubble?
            if ProcessInfo.processInfo.environment["TELOS_RECORDING_CAMERA"] != nil, let camera = AVCaptureDevice.default(for: .video) {
                let created = RecordingCameraBubble()
                if created.use(camera.uniqueID) { created.place(in: area); created.show(); bubble = created }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                report["items_camera"] = telosStatusItems()
            }
            let url = output.deletingPathExtension().appendingPathExtension("mp4")
            try? FileManager.default.removeItem(at: url)
            let recorder = ScreenRecorder(url: url)
            try await recorder.start(filter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config)
            try await Task.sleep(nanoseconds: 1_500_000_000)
            report["items_during"] = telosStatusItems()
            try await Task.sleep(nanoseconds: 500_000_000)
            report["stop_error"] = (await recorder.stop()).map { "\($0)" } ?? "none"
            bubble?.close()
            let asset = AVURLAsset(url: url)
            report["duration"] = try await asset.load(.duration).seconds
            var tracks: [String] = []
            for track in try await asset.load(.tracks) { tracks.append("\(track.mediaType.rawValue) \(try await track.load(.naturalSize))") }
            report["tracks"] = tracks
            let generator = AVAssetImageGenerator(asset: asset)
            let (frame, _) = try await generator.image(at: CMTime(value: 1, timescale: 1))
            try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])?
                .write(to: output.deletingPathExtension().appendingPathExtension("png"))
            // The system capture indicator should be gone once the stream has stopped.
            try await Task.sleep(nanoseconds: 5_000_000_000)
            report["items_after"] = telosStatusItems()
        } catch { report["error"] = "\(error)" }
        panel.orderOut(nil)
    }
    /// Menu bar items owned by any Telos process, including ScreenCaptureKit's capture indicator.
    private static func telosStatusItems() -> String {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 25 && ($0[kCGWindowName as String] as? String) == Bundle.main.bundleIdentifier }
            .compactMap { ($0[kCGWindowBounds as String] as? [String: Double]).map { "x\(Int($0["X"] ?? 0))w\(Int($0["Width"] ?? 0))" } }
            .sorted().joined(separator: ",")
    }
    /// Captures the selection overlay before and after an area is chosen, then the stop bar.
    @MainActor static func snapshots(_ controller: ScreenRecordingController, output: URL) async {
        defer { NSApp.terminate(nil) }
        guard let screen = NSScreen.main else { return }
        func capture(_ name: String) async {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == screen.recordingDisplayID }) else { return }
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * screen.backingScaleFactor); config.height = Int(screen.frame.height * screen.backingScaleFactor)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config) else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent(name + ".png"))
        }
        controller.start()
        await capture("1-initial")
        let f = screen.frame
        controller.drag(from: CGPoint(x: f.minX + f.width * 0.2, y: f.minY + f.height * 0.25), to: CGPoint(x: f.minX + f.width * 0.75, y: f.minY + f.height * 0.8), on: screen)
        await capture("2-dragging")
        controller.endDrag(on: screen)
        await capture("3-selected-off")
        controller.setup.microphone = controller.setup.microphones.first?.id ?? "x"
        controller.setup.camera = controller.setup.cameras.first?.id ?? "x"
        controller.setup.systemAudio = true
        // Allow time for a first-run camera permission prompt, then for the camera to warm up.
        for _ in 0..<90 where AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined || controller.camera == nil {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if AVCaptureDevice.authorizationStatus(for: .video) == .denied { break }
        }
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        await capture("4-selected-on")
        if let bubble = controller.camera {
            bubble.window.setFrameOrigin(CGPoint(x: bubble.window.frame.minX + 300, y: bubble.window.frame.minY + 120))
            controller.drag(from: CGPoint(x: f.minX + f.width * 0.1, y: f.minY + f.height * 0.1), to: CGPoint(x: f.minX + f.width * 0.5, y: f.minY + f.height * 0.5), on: screen)
            controller.endDrag(on: screen)
            await capture("4b-moved-bubble-stays")
        }
        controller.toggleWindowMode()
        controller.hover(at: NSEvent.mouseLocation)
        await capture("5-window-mode")
        controller.cancel()
        let panel = RecordingStopPanel(); panel.sharingType = .readOnly; panel.show(on: screen); panel.model.state = .recording(Date().addingTimeInterval(-13))
        // A setup bar beside the stop bar, on the same background, to compare their glass and shadow.
        let reference = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        reference.isOpaque = false; reference.backgroundColor = .clear; reference.hasShadow = false; reference.level = .statusBar
        let referenceHost = NSHostingView(rootView: RecordingSetupBar(setup: RecordingSetup()) {})
        reference.contentView = referenceHost
        reference.setFrame(NSRect(origin: CGPoint(x: panel.frame.maxX + 8, y: panel.frame.midY - referenceHost.fittingSize.height / 2), size: referenceHost.fittingSize), display: true)
        reference.orderFrontRegardless()
        await capture("6-stop-bar")
        reference.orderOut(nil)
        panel.model.state = .saved
        await capture("7-saved")
    }
}
#endif
