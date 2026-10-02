import AppKit
import ImageIO
import UniformTypeIdentifiers
#if canImport(PaperKit)
import PaperKit
#elseif TELOS_REQUIRE_PAPERKIT
#error("This SDK does not expose PaperKit. Select a macOS SDK with public PaperKit support.")
#endif

/// Keeps screenshot windows independent of the transient menu-bar panel.
/// No screenshot or markup is sent to the agent or any network service.
@MainActor final class ScreenshotEditor {
    private var windows: [UUID: NSWindowController] = [:]
    static var isSupported: Bool {
        #if canImport(PaperKit)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    func show(pngData: Data) throws {
        #if canImport(PaperKit)
        if #available(macOS 26.0, *) {
            let raster = try ScreenshotRaster(pngData: pngData)
            present(raster: raster, markup: PaperMarkup(bounds: raster.bounds))
            return
        }
        #endif
        throw ScreenshotEditorError.unavailable
    }

    #if canImport(PaperKit)
    @available(macOS 26.0, *)
    private func openEditable(_ data: Data) throws {
        let document = try ScreenshotMarkupDocument.decode(data)
        let raster = try ScreenshotRaster(pngData: document.originalPNG,
            canvasSize: CGSize(width: CGFloat(document.canvasWidth), height: CGFloat(document.canvasHeight)))
        let markup = try PaperMarkup(dataRepresentation: document.markupData)
        let supported = ScreenshotMarkupViewController.features
        guard markup.bounds == raster.bounds,
              markup.featureSet.contentVersion == supported.contentVersion,
              markup.featureSet.features.isSubset(of: supported.features) else {
            throw ScreenshotEditorError.incompatibleMarkup
        }
        // Never strip unsupported elements or silently overwrite the user's file.
        present(raster: raster, markup: markup)
    }

    @available(macOS 26.0, *)
    private func present(raster: ScreenshotRaster, markup: PaperMarkup) {
        let id = UUID()
        let controller = ScreenshotMarkupWindowController(raster: raster, markup: markup)
        controller.onClose = { [weak self] in self?.windows.removeValue(forKey: id) }
        controller.editor.openEditable = { [weak self] data in
            guard let self else { return }
            try self.openEditable(data)
        }
        windows[id] = controller
        controller.showWindow(nil)
        controller.window?.center()
        controller.window?.makeKeyAndOrderFront(nil)
        controller.installShortcuts()
        NSApp.activate(ignoringOtherApps: true)
    }
    #endif
}

enum ScreenshotEditorError: LocalizedError {
    case unavailable, invalidImage, renderFailed, incompatibleMarkup
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Screenshot markup requires macOS 26 and a Telos build with PaperKit support."
        case .invalidImage: return "The screenshot could not be read, or is too large to edit safely."
        case .renderFailed: return "The edited image could not be exported. Your original screenshot has not been changed."
        case .incompatibleMarkup: return "This editable copy uses unsupported markup. Update Telos or macOS to open it. The file has not been changed."
        }
    }
}

#if canImport(PaperKit)
@available(macOS 26.0, *)
struct ScreenshotRaster {
    let pngData: Data
    let image: CGImage
    let canvasSize: CGSize
    var bounds: CGRect { CGRect(origin: .zero, size: canvasSize) }

    init(pngData: Data, canvasSize: CGSize? = nil) throws {
        guard pngData.count <= ScreenshotMarkupDocument.maximumImageBytes,
              let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 100_000, height <= 100_000,
              width <= 80_000_000 / height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotEditorError.invalidImage
        }
        self.pngData = pngData
        self.image = image
        func logicalLength(_ pixels: Int, _ dpiKey: CFString) -> CGFloat {
            let dpi = (properties[dpiKey] as? NSNumber)?.doubleValue ?? 72
            return CGFloat(Double(pixels) * 72 / (dpi.isFinite && dpi > 0 ? dpi : 72))
        }
        let size = canvasSize ?? CGSize(width: logicalLength(width, kCGImagePropertyDPIWidth),
                                        height: logicalLength(height, kCGImagePropertyDPIHeight))
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              size.width <= 100_000, size.height <= 100_000 else { throw ScreenshotEditorError.invalidImage }
        self.canvasSize = size
    }
}

@available(macOS 26.0, *)
@MainActor enum ScreenshotMarkupRenderer {
    static func png(raster: ScreenshotRaster, markup: PaperMarkup) async throws -> Data {
        if markup.contentsRenderFrame.isEmpty || markup.contentsRenderFrame.isNull { return raster.pngData }
        let width = raster.image.width, height = raster.image.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenshotEditorError.renderFailed
        }
        // Compose both layers in ONE PaperKit coordinate system. The background
        // is only inserted into this disposable export model, never the editor.
        var composite = PaperMarkup(bounds: raster.bounds)
        composite.insertNewImage(raster.image, frame: raster.bounds, rotation: 0)
        composite.append(contentsOf: markup)
        let pixels = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: pixels)
        await composite.draw(in: context, frame: pixels)
        guard let image = context.makeImage() else { throw ScreenshotEditorError.renderFailed }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenshotEditorError.renderFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: Double(width) * 72 / Double(raster.canvasSize.width),
            kCGImagePropertyDPIHeight: Double(height) * 72 / Double(raster.canvasSize.height)
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotEditorError.renderFailed }
        return data as Data
    }
}

@available(macOS 26.0, *)
@MainActor private final class ScreenshotBackgroundView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@available(macOS 26.0, *)
@MainActor private final class ScreenshotMarkupWindow: NSWindow {
    private let documentUndoManager = UndoManager()
    override var undoManager: UndoManager? { documentUndoManager }
}

@available(macOS 26.0, *)
@MainActor private final class ScreenshotMarkupWindowController: NSWindowController, NSWindowDelegate {
    let editor: ScreenshotMarkupViewController
    var onClose: () -> Void = {}
    private var keyMonitor: Any?

    init(raster: ScreenshotRaster, markup: PaperMarkup) {
        editor = ScreenshotMarkupViewController(raster: raster, markup: markup)
        let window = ScreenshotMarkupWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Screenshot · Telos"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 740, height: 360)
        window.contentViewController = editor
        super.init(window: window)
        window.delegate = self
        if let screen = NSScreen.main {
            window.setContentSize(NSSize(width: min(960, screen.visibleFrame.width - 40),
                                         height: min(680, screen.visibleFrame.height - 80)))
        }
    }
    required init?(coder: NSCoder) { return nil }

    func installShortcuts() {
        guard keyMonitor == nil else { return }
        // Telos's menu-bar app explicitly targets Cmd-W at Hide Telos. Intercept
        // only this editor's keys, before the main menu, without changing it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
            if self.editor.busy { return nil }
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags == [.command], key == "w" { self.window?.performClose(nil); return nil }
            if flags == [.command], key == "s" { self.editor.savePNG(nil); return nil }
            if flags == [.command, .shift], key == "s" { self.editor.saveEditableCopy(nil); return nil }
            if flags == [.command, .shift], key == "c" { self.editor.copyImage(nil); return nil }
            if flags == [.command, .shift], key == "z" {
                if !self.editor.busy { self.window?.firstResponder?.undoManager?.redo() }
                return nil
            }
            return event
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { editor.shouldClose() }
    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        onClose()
    }
}

@available(macOS 26.0, *)
@MainActor private final class ScreenshotMarkupViewController: NSViewController, PaperMarkupViewController.Delegate {
    static var features: FeatureSet {
        var features = FeatureSet.version1
        features.features.subtract([.images, .stickers, .links, .loupes])
        return features
    }
    let raster: ScreenshotRaster
    let paper: PaperMarkupViewController
    let tools: MarkupToolbarViewController
    var openEditable: (Data) throws -> Void = { _ in }
    private(set) var busy = false
    private var dirty = false
    private var revision: UInt = 0
    private var mayClose = false
    private var hasFitted = false
    private var buttons: [NSControl] = []
    private let status = NSTextField(labelWithString: "Markup stays separate from the original.")

    init(raster: ScreenshotRaster, markup: PaperMarkup) {
        self.raster = raster
        paper = PaperMarkupViewController(markup: markup, supportedFeatureSet: Self.features)
        tools = MarkupToolbarViewController(supportedFeatureSet: Self.features)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { return nil }
    override func loadView() { view = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 680)) }
    override func viewDidLoad() {
        super.viewDidLoad()
        let background = ScreenshotBackgroundView(frame: raster.bounds)
        background.image = NSImage(cgImage: raster.image, size: raster.canvasSize)
        background.imageScaling = .scaleAxesIndependently
        background.isEditable = false
        paper.contentView = background
        paper.zoomRange = 0.01...8
        paper.indirectPointerTouchMode = .drawing
        tools.delegate = paper
        tools.indirectPointerTouchModes = [.drawing, .selection]
        tools.selectedIndirectPointerTouchMode = .drawing
        for child in [paper as NSViewController, tools as NSViewController] {
            addChild(child)
            child.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child.view)
        }
        let undo = button("Undo", #selector(undoMarkup(_:)))
        let redo = button("Redo", #selector(redoMarkup(_:)))
        let fit = button("Fit", #selector(fitImage(_:)))
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.addItem(withTitle: "More")
        for (title, action) in [("Open Editable…", #selector(openEditableCopy(_:))),
                                 ("Save Editable…", #selector(saveEditableCopy(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            more.menu?.addItem(item)
        }
        more.toolTip = "Save or reopen an editable copy, including the original screenshot."
        buttons.append(more)
        let save = button("Save PNG…", #selector(savePNG(_:)))
        let copy = button("Copy Image", #selector(copyImage(_:)))
        copy.toolTip = "Copy the original-resolution image with your markup (Shift-Command-C)."
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [undo, redo, fit, more, status, save, copy])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            tools.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            tools.view.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tools.view.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tools.view.heightAnchor.constraint(equalToConstant: 64),
            paper.view.topAnchor.constraint(equalTo: tools.view.bottomAnchor, constant: 8),
            paper.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            paper.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            paper.view.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            footer.heightAnchor.constraint(equalToConstant: 32)
        ])
        paper.delegate = self
    }
    override func viewDidLayout() {
        super.viewDidLayout()
        if !hasFitted, paper.view.bounds.width > 0, paper.view.bounds.height > 0 {
            hasFitted = true
            fitImage(nil)
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(paper)
    }
    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        buttons.append(button)
        return button
    }
    func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {
        revision &+= 1
        dirty = true
        view.window?.isDocumentEdited = true
        status.stringValue = "Markup is separate from the original."
    }
    @objc private func fitImage(_ sender: Any?) { paper.setContentVisibleFrame(raster.bounds, animated: false) }
    @objc private func undoMarkup(_ sender: Any?) { if !busy { paper.undoManager?.undo() } }
    @objc private func redoMarkup(_ sender: Any?) { if !busy { paper.undoManager?.redo() } }

    @objc func copyImage(_ sender: Any?) {
        performExport { [self] markup in
            let data = try await ScreenshotMarkupRenderer.png(raster: raster, markup: markup)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(data, forType: .png) else { throw ScreenshotEditorError.renderFailed }
            return "Copied at \(raster.image.width) × \(raster.image.height) pixels."
        }
    }
    @objc func savePNG(_ sender: Any?) {
        chooseDestination(editable: false) { [weak self] url in
            guard let self else { return }
            self.performExport { [self] markup in
                let data = try await ScreenshotMarkupRenderer.png(raster: raster, markup: markup)
                try data.write(to: url, options: .atomic)
                return "PNG saved."
            }
        }
    }
    @objc func saveEditableCopy(_ sender: Any?) { saveEditable(closeAfterSaving: false) }
    private func saveEditable(closeAfterSaving: Bool) {
        chooseDestination(editable: true) { [weak self] url in
            guard let self else { return }
            self.performExport({ [self] markup in
                let markupData = try await markup.dataRepresentation()
                let preview = try await ScreenshotMarkupRenderer.png(raster: raster, markup: markup)
                let document = try ScreenshotMarkupDocument(originalPNG: raster.pngData,
                    markupData: markupData, previewPNG: preview,
                    canvasWidth: Double(raster.canvasSize.width), canvasHeight: Double(raster.canvasSize.height))
                try document.encoded().write(to: url, options: .atomic)
                return "Editable copy saved."
            }, completed: { [weak self] unchanged in
                guard let self else { return }
                guard unchanged else {
                    self.status.stringValue = "Saved a copy. Newer edits are still unsaved."
                    return
                }
                self.dirty = false
                self.view.window?.isDocumentEdited = false
                if closeAfterSaving { self.mayClose = true; self.view.window?.performClose(nil) }
            })
        }
    }
    private func chooseDestination(editable: Bool, chosen: @escaping (URL) -> Void) {
        guard !busy, let window = view.window, window.attachedSheet == nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = editable ? [.json] : [.png]
        panel.nameFieldStringValue = editable ? "Screenshot.telosshot.json" : "Screenshot.png"
        panel.canCreateDirectories = true
        if editable { panel.message = "Editable copies include the unedited original screenshot. To share only the visible result, use Save PNG instead." }
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { chosen(url) }
        }
    }
    @objc private func openEditableCopy(_ sender: Any?) {
        guard !busy, let window = view.window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a Telos editable screenshot (.telosshot.json)."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let bytes = values.fileSize, bytes <= ScreenshotMarkupDocument.maximumFileBytes else {
                    throw ScreenshotMarkupDocument.DocumentError.tooLarge
                }
                try self.openEditable(Data(contentsOf: url, options: .mappedIfSafe))
            } catch { self.showError(error) }
        }
    }
    private func performExport(_ operation: @escaping @MainActor (PaperMarkup) async throws -> String,
                               completed: ((Bool) -> Void)? = nil) {
        guard !busy else { return }
        if let window = view.window, !window.makeFirstResponder(nil) { return }
        guard let markup = paper.markup else { return }
        let exportedRevision = revision
        busy = true
        setBusyUI()
        status.stringValue = "Exporting…"
        Task { [self] in
            do {
                let message = try await operation(markup)
                busy = false
                setBusyUI()
                status.stringValue = message
                completed?(revision == exportedRevision)
            } catch {
                busy = false
                setBusyUI()
                status.stringValue = "Export failed. Your edits are still here."
                showError(error)
            }
        }
    }
    private func setBusyUI() {
        paper.isEditable = !busy
        tools.view.isHidden = busy
        buttons.forEach { $0.isEnabled = !busy }
    }
    func shouldClose() -> Bool {
        if mayClose { return true }
        guard !busy, let window = view.window, window.attachedSheet == nil else { return false }
        // Commit an in-progress text box before deciding whether there are edits.
        guard window.makeFirstResponder(nil) else { return false }
        guard dirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Keep an editable copy?"
        alert.informativeText = "Copied or exported PNGs will remain, but you need an editable copy to change these annotations later."
        alert.addButton(withTitle: "Save Editable…")
        alert.addButton(withTitle: "Discard Edits")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.saveEditable(closeAfterSaving: true) }
            else if response == .alertSecondButtonReturn {
                self.mayClose = true
                self.view.window?.performClose(nil)
            }
        }
        return false
    }
    private func showError(_ error: Error) {
        guard let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Screenshot Editor"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
#endif
