import AppKit
import SwiftUI

@main struct ComposerEditingTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let draft = ComposerDraft()
        let window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: VStack {
            Spacer()
            Composer(draft: draft, placeholder: "Add a comment", identifier: "test", action: {})
                .padding(16)
        }.frame(width: 400, height: 400))
        window.makeKeyAndOrderFront(nil)
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
        settle()
        guard let editor = draft.editor else { fatalError("No editor") }
        window.makeFirstResponder(editor)
        window.makeFirstResponder(nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: editor.convert(NSPoint(x: 2, y: 5), to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        editor.beginPointerEditing(down)
        precondition(window.firstResponder === editor && editor.shouldDrawInsertionPoint && draft.isPressed, "Caret is active before mouseUp")
        draft.isPressed = false
        precondition(draft.isFocused)
        let editorPoint = editor.convert(NSPoint(x: 4, y: 4), to: nil)
        precondition(DictationController.localEditor(in: window, at: editorPoint) === editor, "Native input is a valid dictation target")
        precondition(DictationController.localEditor(in: window, at: NSPoint(x: 200, y: 350)) == nil, "Text outside the editor cannot dictate")
        editor.isEditable = false
        precondition(DictationController.localEditor(in: window, at: editorPoint) == nil, "Read-only text cannot dictate")
        editor.isEditable = true
        window.dismissInputFocus(at: editorPoint)
        precondition(window.firstResponder === editor && draft.isFocused, "Inside click retains editing")
        window.dismissInputFocus(at: NSPoint(x: 200, y: 350))
        precondition(window.firstResponder !== editor && !draft.isFocused, "Outside click clears focus")
        window.makeFirstResponder(editor)
        let original = editor.convert(editor.bounds, to: window.contentView)
        precondition(draft.showsPlaceholder)
        for text in ["n", "ni", "nih", "nihao"] {
            editor.setMarkedText(text, selectedRange: NSRange(location: text.utf16.count, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            precondition(!draft.showsPlaceholder && draft.isComposing, "Hide placeholder immediately for IME")
            settle()
            precondition(editor.hasMarkedText(), "Rendering must preserve IME composition")
            let current = editor.convert(editor.bounds, to: window.contentView)
            precondition(abs(current.minY - original.minY) < 0.5 && abs(current.height - original.height) < 0.5, "Single-line composition moved the editor")
        }
        editor.insertText("你好", replacementRange: NSRange(location: NSNotFound, length: 0))
        settle()
        precondition(!draft.isComposing && draft.text == "你好")
        let committed = editor.convert(editor.bounds, to: window.contentView)
        precondition(abs(committed.minY - original.minY) < 0.5)
        draft.setText(String(repeating: "多行文字 mixed English ", count: 15)); settle(); settle()
        precondition(draft.editorHeight > 20 && draft.editorHeight <= 144)
        let height = draft.editorHeight; settle()
        precondition(draft.editorHeight == height, "Height must settle without oscillation")
        let longText = String(repeating: "长文编辑 mixed English 👩🏽‍💻\n", count: 5000)
        let started = Date()
        draft.setText(longText); settle(); settle()
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("CHECK ", replacementRange: editor.selectedRange()); settle()
        precondition(draft.text == "CHECK " + longText && draft.editorHeight <= 144)
        precondition(Date().timeIntervalSince(started) < 5, "Long drafts must remain editable without full relayout loops")
        draft.clear(); settle(); settle()
        precondition(draft.showsPlaceholder && draft.editorHeight == 20)
        editor.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.unmarkText(); settle()
        precondition(draft.showsPlaceholder, "Cancelled composition restores placeholder")
        window.orderOut(nil)
        print("PASS: mouse-down caret activation, outside-click focus dismissal, IME placeholder, marked-text preservation, stable single-line frame, multiline sizing and cancellation")
    }
}
