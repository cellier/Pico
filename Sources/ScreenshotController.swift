import AppKit
import Carbon

/// Uses the system selection UI: crosshair drag, Space for windows, Escape to cancel.
/// Capture locally, then open the editor. Local edits stay offline; annotation mode uses the configured provider.
@MainActor final class ScreenshotController {
    static let arguments = ["-i", "-c", "-d", "-Jselection", "-t", "png"]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var capture: Process?
    private var pending: Task<Void, Never>?
    var captured: (NSImage) -> Void = { _ in }
    var prepare: () -> Void = {}
    var finished: () -> Void = {}
    var isSelecting: Bool { pending != nil || capture != nil }
    var failed: (String) -> Void = { _ in }

    func register() -> OSStatus {
        guard hotKey == nil else { return noErr }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == 0x544C5353, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<ScreenshotController>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { controller.start() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return installed }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey), EventHotKeyID(signature: 0x544C5353, id: 1),
                                         GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr, let handler { RemoveEventHandler(handler); self.handler = nil }
        return result
    }

    func start() {
        guard pending == nil, capture == nil else { return }
        prepare()
        pending = Task { [weak self] in
            // Defer to the next turn so menus can dismiss without hiding Telos.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = Self.arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pasteboardChange = NSPasteboard.general.changeCount
            process.terminationHandler = { [weak self] ended in
                Task { @MainActor in
                    guard let self, self.capture === ended else { return }
                    self.capture = nil
                    if ended.terminationStatus == 0, NSPasteboard.general.changeCount != pasteboardChange, let image = NSImage(pasteboard: .general) {
                        // Publish standard image formats before opening the editor.
                        // The editor's Copy button is only needed for subsequent edits.
                        if !Self.copyCapturedImage(image) { self.failed("Could not copy the screenshot. Try Copy in the editor.") }
                        self.finished()
                        self.captured(image)
                    } else { self.finished() }
                }
            }
            self.capture = process
            do { try process.run() }
            catch {
                self.capture = nil; self.finished()
                self.failed("Could not start macOS screenshot selection. Please try again.")
            }
            // Native -d displays permission/capture errors. Escape is a normal cancellation.
        }
    }

    @discardableResult
    static func copyCapturedImage(_ image: NSImage, to pasteboard: NSPasteboard = .general) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let item = NSPasteboardItem()
        guard item.setData(png, forType: .png), item.setData(tiff, forType: .tiff) else { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    func stop() {
        let wasSelecting = isSelecting
        pending?.cancel(); pending = nil
        if let capture, capture.isRunning { capture.terminate() }
        capture = nil
        if wasSelecting { finished() }
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
