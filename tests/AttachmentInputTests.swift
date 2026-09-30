import Foundation
import AppKit
@main struct InlineAttachmentTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TelosAttachmentTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("TELOS_DATA_DIR", root.appendingPathComponent("data").path, 1)
        let source = root.appendingPathComponent("notes.txt")
        try Data("Hello attachment".utf8).write(to: source)
        let draft = ComposerDraft()
        let editor = AttachmentTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        let coordinator = InlineComposerEditor.Coordinator(draft)
        defer { withExtendedLifetime(coordinator) {} }
        editor.delegate = coordinator; editor.draft = draft; draft.editor = editor; editor.isRichText = true; editor.allowsUndo = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.insertText("Before After", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        draft.insert([source])
        precondition(draft.files.count == 1)
        precondition(draft.text == "Before [Attachment: notes.txt]After", draft.text)
        let staged = draft.files[0].path
        precondition(staged != source.path)
        // Let the insertion event finish before the separate delete/undo event.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        editor.setSelectedRange(NSRange(location: 8, length: 0)); editor.deleteBackward(nil)
        editor.undoManager?.endUndoGrouping()
        precondition(draft.files.isEmpty && draft.text == "Before After")
        editor.undoManager?.undoNestedGroup()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(draft.files.count == 1, "Undo restores attachment")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let board = NSPasteboard.withUniqueName(); board.writeObjects([source as NSURL])
        precondition(draft.paste(board) && draft.files.count == 2)
        let store = TaskStore()
        let id = store.add(draft.text, files: draft.files)!
        let message = store.tasks[0].messages[0]
        precondition(message.files?.count == 2)
        precondition(message.files![0].path != message.files![1].path)
        let saved = root.appendingPathComponent("data/tasks/\(id.uuidString.lowercased())/files/" + message.files![0].path)
        let savedText = try String(contentsOf: saved, encoding: .utf8)
        precondition(savedText == "Hello attachment")
        precondition(message.attachmentPrompt!.contains(message.files![0].path))
        draft.clear()
        precondition(FileManager.default.fileExists(atPath: saved.path))
        precondition(FileManager.default.fileExists(atPath: source.path))
        precondition(!FileManager.default.fileExists(atPath: staged))
        let restored = TaskStore()
        precondition(restored.tasks[0].messages[0].files?.count == 2)
        precondition(restored.ask(id, text: "Follow up", files: [ComposerFile(name: "notes.txt", path: source.path)]))
        precondition(restored.tasks[0].messages.last?.files?.count == 1)
        let count = restored.tasks.count
        precondition(restored.add("bad", files: [ComposerFile(name: "missing", path: root.appendingPathComponent("missing").path)]) == nil)
        precondition(restored.tasks.count == count)
        print("PASS: caret insertion, atomic deletion/undo, file paste, task/follow-up file copies, persistence, failure isolation, original preservation")
    }
}
