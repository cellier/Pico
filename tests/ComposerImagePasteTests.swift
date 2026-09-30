import AppKit
import SwiftUI
@main struct ComposerImagePasteTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let general = NSPasteboard.general
        let original = general.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        var ownedChange = general.changeCount
        defer {
            if general.changeCount == ownedChange { general.clearContents(); general.writeObjects(original) }
        }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = image.representation(using: .png, properties: [:])!
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(png, forType: .png)
        for detail in [false, true] {
            let draft = ComposerDraft()
            let window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
            if detail { window.contentView = NSHostingView(rootView: Composer(draft: draft, placeholder: "Add a comment", identifier: "askField", action: {}).frame(width: 360)) }
            else { window.contentView = NSHostingView(rootView: TaskComposer(draft: draft, action: {}).frame(width: 360)) }
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            guard let editor = draft.editor else { fatalError("Missing input") }
            window.makeFirstResponder(editor)
            precondition(editor.readablePasteboardTypes.contains(.png) && editor.readablePasteboardTypes.contains(.tiff))
            let accepted = editor.readSelection(from: board, type: .png)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            precondition(accepted && draft.files.count == 1 && draft.content.length == 1, "Native image paste must create a Telos attachment")
            precondition(!draft.showsPlaceholder && draft.hasContent && draft.editorHeight >= 28)
            precondition(NSImage(contentsOfFile: draft.files[0].path) != nil)
            let attachment = draft.content.attribute(.attachment, at: 0, effectiveRange: nil) as! FileAttachment
            precondition((attachment.attachmentCell as! FileChip).thumbnail != nil)
            editor.setSelectedRange(NSRange(location: 1, length: 0))
            editor.breakUndoCoalescing()
            editor.undoManager?.beginUndoGrouping()
            editor.deleteBackward(nil)
            editor.undoManager?.endUndoGrouping()
            precondition(draft.files.isEmpty && draft.showsPlaceholder)
            editor.undoManager?.undoNestedGroup()
            precondition(draft.files.count == 1, "Undo restores pasted image")
            editor.selectAll(nil)
            board.clearContents(); board.setData(image.tiffRepresentation!, forType: .tiff)
            precondition(editor.readSelection(from: board, type: .tiff))
            precondition(draft.files.count == 1, "Paste replaces selection, not appends invisibly")
            board.clearContents(); board.setData(png, forType: .png)
            print("PASS:", detail ? "detail composer" : "home composer", "PNG/TIFF paste, visible thumbnail, placeholder, height, delete and undo")
            editor.selectAll(nil)
            general.clearContents(); general.setData(png, forType: .png); ownedChange = general.changeCount
            let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            precondition(editor.validateMenuItem(pasteItem), "Command-V must be enabled for an image-only clipboard")
            precondition(NSApp.sendAction(pasteItem.action!, to: editor, from: pasteItem))
            precondition(draft.files.count == 1 && !draft.showsPlaceholder)
            print("PASS: native Paste menu validation and action for image-only clipboard")
            window.orderOut(nil)
        }
    }
}
