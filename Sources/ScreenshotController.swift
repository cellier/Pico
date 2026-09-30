import AppKit
import Carbon

/// Uses the system selection UI: crosshair drag, Space for windows, Escape to cancel.
/// Captures go directly to the pasteboard; no file or agent upload is involved.
@MainActor final class ScreenshotController {
    static let arguments = ["-i", "-c", "-d", "-Jselection", "-t", "png"]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var capture: Process?
    private var pending: Task<Void, Never>?
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
            process.terminationHandler = { [weak self] ended in
                Task { @MainActor in
                    guard let self, self.capture === ended else { return }
                    self.capture = nil; self.finished()
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
