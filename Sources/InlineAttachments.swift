import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

struct ComposerFile: Codable {
    var name: String
    var path: String
}
final class FileAttachment: NSTextAttachment {
    let file: ComposerFile
    init(file: ComposerFile) {
        self.file = file
        super.init(data: nil, ofType: nil)
        let chip = FileChip(textCell: file.name)
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: file.path) as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 48, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
            chip.thumbnail = NSImage(cgImage: image, size: NSSize(width: 20, height: 20))
        }
        attachmentCell = chip
    }
    required init?(coder: NSCoder) { nil }
}
final class FileChip: NSTextAttachmentCell {
    var hovered = false
    var thumbnail: NSImage?
    override func cellSize() -> NSSize { NSSize(width: min(220, CGFloat(stringValue.count) * 7 + 44), height: 28) }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: -7) }
    override func draw(withFrame frame: NSRect, in view: NSView?) {
        TelosTheme.native(1, 0.23).setFill(); NSColor.separatorColor.setStroke()
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        path.fill(); path.stroke()
        let symbol = NSImage(systemSymbolName: hovered ? "xmark.circle.fill" : "doc", accessibilityDescription: hovered ? "Remove attachment" : "Attachment")
        (hovered ? symbol : (thumbnail ?? symbol))?.draw(in: NSRect(x: frame.minX + 7, y: frame.minY + 6, width: 16, height: 16))
        (stringValue as NSString).draw(in: NSRect(x: frame.minX + 28, y: frame.minY + 6, width: frame.width - 34, height: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
    }
}
@MainActor final class ComposerDraft: ObservableObject {
    @Published var content = NSAttributedString(string: "")
    @Published var error: String?
    @Published var isHovered = false
    @Published var isFocused = false
    @Published var isPressed = false
    @Published var isComposing = false
    @Published var editorHeight: CGFloat = 20
    var showsPlaceholder: Bool { content.length == 0 && !isComposing }
    weak var hitSurface: NSView?
    weak var editor: AttachmentTextView?
    private let staging = FileManager.default.temporaryDirectory.appendingPathComponent("TelosDraft-" + UUID().uuidString)
    var compactLayoutHeight: CGFloat {
        let storage = NSTextStorage(attributedString: content)
        let layout = NSLayoutManager(); let container = NSTextContainer(size: NSSize(width: 260, height: 10000))
        container.lineFragmentPadding = 0; layout.addTextContainer(container); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return min(144, max(20, ceil(layout.usedRect(for: container).height)))
    }
    var hasContent: Bool { !content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var files: [ComposerFile] {
        var result: [ComposerFile] = []
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length)) { value, _, _ in
            if let a = value as? FileAttachment { result.append(a.file) }
        }
        return result
    }
    var text: String {
        let result = NSMutableAttributedString(attributedString: content)
        content.enumerateAttribute(.attachment, in: NSRange(location: 0, length: content.length), options: .reverse) { value, range, _ in
            if let a = value as? FileAttachment { result.replaceCharacters(in: range, with: "[Attachment: \(a.file.name)]") }
        }
        return result.string
    }
    func setText(_ text: String) { content = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]) }
    func clear() { setText(""); editor?.undoManager?.removeAllActions(); try? FileManager.default.removeItem(at: staging) }
    func chooseFiles() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in if response == .OK { self?.insert(panel.urls) } }
    }
    func insert(_ urls: [URL]) {
        do {
            let value = NSMutableAttributedString(string: "")
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard info.isRegularFile == true, (info.fileSize ?? 0) <= 50 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                let dir = staging.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let copy = dir.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: copy)
                value.append(NSAttributedString(attachment: FileAttachment(file: ComposerFile(name: url.lastPathComponent, path: copy.path))))
            }
            if let editor {
                editor.insertText(value, replacementRange: editor.selectedRange())
                editor.window?.makeFirstResponder(editor)
            } else {
                let updated = NSMutableAttributedString(attributedString: content)
                updated.append(value); content = updated
            }
        } catch { self.error = "Could not attach file (maximum 50 MB): \(error.localizedDescription)" }
    }
    func paste(_ board: NSPasteboard) -> Bool {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { insert(urls); return true }
        if let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Image-\(UUID().uuidString).png")
            do { try png.write(to: url); insert([url]); try? FileManager.default.removeItem(at: url) } catch { self.error = error.localizedDescription }
            return true
        }
        return false
    }
    deinit { try? FileManager.default.removeItem(at: staging) }
}
final class AttachmentTextView: NSTextView, DictationInputSurfaceProviding {
    var dictationInputSurface: NSView? { draft?.hitSurface }
    weak var draft: ComposerDraft?
    var submit: () -> Void = {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { let result = super.becomeFirstResponder(); if result { draft?.isFocused = true }; return result }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { draft?.isFocused = false }; return result }

    private var measurementQueued = false
    func scheduleMeasurement() {
        guard !measurementQueued else { return }
        measurementQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementQueued = false
            guard let layout = self.layoutManager, let container = self.textContainer else { return }
            layout.ensureLayout(for: container)
            var height = layout.usedRect(for: container).maxY
            if layout.extraLineFragmentTextContainer === container {
                height = max(height, layout.extraLineFragmentRect.maxY)
            }
            let measured = min(144, max(20, ceil(height + self.textContainerInset.height * 2)))
            if self.draft?.editorHeight != measured { self.draft?.editorHeight = measured }
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        let changedWidth = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changedWidth { scheduleMeasurement() }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        publishEditingState()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        publishEditingState()
    }
    override func unmarkText() {
        super.unmarkText()
        publishEditingState()
    }
    override func didChangeText() {
        super.didChangeText()
        // Native Undo can restore attachments without calling insertText again.
        publishEditingState()
    }
    func publishEditingState() {
        draft?.isComposing = hasMarkedText()
        draft?.content = NSAttributedString(attributedString: attributedString())
        scheduleMeasurement()
    }
    // AppKit validates Paste and routes context-menu/services imports using these types.
    // Keep native graphics import disabled: every image must become our removable FileAttachment.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]
        types += NSImage.imageTypes.map { NSPasteboard.PasteboardType($0) }
        for type in super.readablePasteboardTypes where !types.contains(type) { types.append(type) }
        return types
    }
    override func readSelection(from board: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if draft?.paste(board) == true { return true }
        return super.readSelection(from: board, type: type)
    }
    override func paste(_ sender: Any?) { if draft?.paste(.general) != true { pasteAsPlainText(sender) } }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        return draft?.paste(sender.draggingPasteboard) ?? false
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 && !event.modifierFlags.contains(.shift) && !hasMarkedText() { submit(); return }
        super.keyDown(with: event)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    func attachments(_ action: (FileChip, NSRange, NSRect) -> Void) {
        guard let storage = textStorage, let layout = layoutManager, let container = textContainer else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let cell = (value as? FileAttachment)?.attachmentCell as? FileChip else { return }
            var rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            rect.origin.x += textContainerOrigin.x; rect.origin.y += textContainerOrigin.y
            action(cell, range, rect)
        }
    }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        attachments { cell, _, rect in cell.hovered = rect.contains(p) }; needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { attachments { cell, _, _ in cell.hovered = false }; needsDisplay = true }
    /// Focus, position and paint the caret before NSTextView enters mouse tracking.
    func beginPointerEditing(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        draft?.isPressed = true
        if event.clickCount == 1 && !event.modifierFlags.contains(.shift) && !hasMarkedText() {
            let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
            let selection = selectedRange()
            // Retain native dragging of selected text and double/triple-click selection.
            if selection.length == 0 || !NSLocationInRange(index, selection) {
                setSelectedRange(NSRange(location: index, length: 0))
            }
        }
        updateInsertionPointStateAndRestartTimer(true)
        needsDisplay = true
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.contentView?.displayIfNeeded()
    }
    override var shouldDrawInsertionPoint: Bool {
        super.shouldDrawInsertionPoint || (draft?.isPressed == true && window?.firstResponder === self && selectedRange().length == 0)
    }
    override func mouseDown(with event: NSEvent) {
        beginPointerEditing(event)
        defer {
            draft?.isPressed = false
            (NSApp.delegate as? AppDelegate)?.dictation.localMouseReleased()
        }
        let p = convert(event.locationInWindow, from: nil); var target: NSRange?
        attachments { cell, range, rect in if cell.hovered && rect.contains(p) && p.x < rect.minX + 26 { target = range } }
        if let target { insertText("", replacementRange: target) } else { super.mouseDown(with: event) }
    }
}
struct InlineComposerEditor: NSViewRepresentable {
    @ObservedObject var draft: ComposerDraft
    var placeholder: String
    var identifier: String
    var action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(draft) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let view = AttachmentTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        view.minSize = NSSize(width: 0, height: 20)
        view.isRichText = true; view.importsGraphics = false; view.allowsUndo = true; view.drawsBackground = false
        view.font = .systemFont(ofSize: 14); view.textColor = .labelColor; view.textContainerInset = NSSize(width: 0, height: 1)
        view.textContainer?.lineFragmentPadding = 0; view.isHorizontallyResizable = false; view.isVerticallyResizable = true
        view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator; view.draft = draft; draft.editor = view
        view.registerForDraggedTypes([.fileURL, .png, .tiff]); view.setAccessibilityIdentifier(identifier)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AttachmentTextView else { return }
        view.submit = action
        if !view.hasMarkedText(), !view.attributedString().isEqual(to: draft.content) {
            view.textStorage?.setAttributedString(draft.content)
            view.scheduleMeasurement()
        }
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        view.setAccessibilityLabel(placeholder)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        let draft: ComposerDraft
        init(_ draft: ComposerDraft) { self.draft = draft }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? AttachmentTextView { view.publishEditingState() } }
    }
}
struct AttachmentInput: View {
    @ObservedObject var draft: ComposerDraft
    var placeholder: String
    var identifier: String
    var action: () -> Void
    var body: some View {
        InlineComposerEditor(draft: draft, placeholder: placeholder, identifier: identifier, action: action)
            .frame(height: draft.editorHeight)
            .transaction { $0.animation = nil }
            .overlay(alignment: .topLeading) { if draft.showsPlaceholder { Text(placeholder).font(.system(size: 14)).foregroundStyle(.secondary).frame(height: 20, alignment: .center).allowsHitTesting(false) } }
            .alert("Attachment", isPresented: Binding(get: { draft.error != nil }, set: { if !$0 { draft.error = nil } })) { Button("OK") { draft.error = nil } } message: { Text(draft.error ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: .init(identifier == "newTaskField" ? "TelosNewTask" : "TelosFocusAsk"))) { _ in draft.editor?.window?.makeFirstResponder(draft.editor) }
    }
}

/// Padding is part of the input target, rather than an inert area around the text view.
struct ComposerHitArea: NSViewRepresentable {
    let draft: ComposerDraft
    func makeNSView(context: Context) -> ComposerHitView {
        let view = ComposerHitView(); view.draft = draft; draft.hitSurface = view; return view
    }
    func updateNSView(_ view: ComposerHitView, context: Context) { view.draft = draft; draft.hitSurface = view }
}
final class ComposerHitView: NSView {
    weak var draft: ComposerDraft?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }
    override func mouseDown(with event: NSEvent) {
        guard let editor = draft?.editor else { return }
        editor.beginPointerEditing(event)
    }
    override func mouseUp(with event: NSEvent) { draft?.isPressed = false; (NSApp.delegate as? AppDelegate)?.dictation.localMouseReleased() }
}
