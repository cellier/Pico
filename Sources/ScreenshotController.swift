import AppKit
import Carbon

/// System selection UI: crosshair drag, Space for windows, Escape to cancel.
/// macOS 26 + a PaperKit SDK: copy the original, then open a local markup editor.
/// Other builds retain direct clipboard capture. Nothing is uploaded to an agent.
@MainActor final class ScreenshotController {
    static let arguments = ["-i", "-c", "-d", "-Jselection", "-t", "png"]
    static func arguments(outputURL: URL?) -> [String] {
        guard let outputURL else { return arguments }
        // An owned output file identifies THIS capture. Never treat a change in
        // the global pasteboard as proof that screenshot selection succeeded.
        return arguments.filter { $0 != "-c" } + [outputURL.path]
    }
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var capture: Process?
    private var pending: Task<Void, Never>?
    private let editor = ScreenshotEditor()
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
            let directory: URL?
            do {
                if ScreenshotEditor.isSupported {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("TelosScreenshot-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                            attributes: [.posixPermissions: 0o700])
                    directory = url
                } else { directory = nil }
            } catch {
                self.finished()
                self.failed("Could not prepare the screenshot editor: \(error.localizedDescription)")
                return
            }
            let output = directory?.appendingPathComponent("capture.png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = Self.arguments(outputURL: output)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] ended in
                Task { @MainActor in
                    // Also remove the owned temporary file after stop() or if
                    // the controller disappeared while screencapture was exiting.
                    defer { if let directory { try? FileManager.default.removeItem(at: directory) } }
                    guard let self, self.capture === ended else { return }
                    self.capture = nil
                    self.finished()
                    // Escape / permission denial must not open an old image or
                    // overwrite the pasteboard. Native -d displays capture errors.
                    guard ended.terminationReason == .exit, ended.terminationStatus == 0,
                          let output, FileManager.default.fileExists(atPath: output.path) else { return }
                    do {
                        let values = try output.resourceValues(forKeys: [.fileSizeKey])
                        guard let size = values.fileSize, size <= ScreenshotMarkupDocument.maximumImageBytes else {
                            throw ScreenshotEditorError.invalidImage
                        }
                        let data = try Data(contentsOf: output)
                        try self.editor.show(pngData: data)
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        if !pasteboard.setData(data, forType: .png) {
                            self.failed("The screenshot is open in the editor, but could not be copied. Use Copy Image to try again.")
                        }
                    } catch { self.failed("Could not open the screenshot editor: \(error.localizedDescription)") }
                }
            }
            self.capture = process
            do { try process.run() }
            catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                self.capture = nil
                self.finished()
                self.failed("Could not start macOS screenshot selection. Please try again.")
            }
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
