import AppKit
import ApplicationServices
@main struct DictationTests {
    static func main() {
        func allowed(_ role: String = kAXTextAreaRole, enabled: Bool? = true,
                     editable: Bool? = nil, secure: Bool = false, range: Bool = true,
                     text: Bool = true, value: Bool = false) -> Bool {
            DictationEditability.allows(role: role, enabled: enabled, editable: editable,
                secure: secure, hasInsertionRange: range, writableText: text, writableValue: value)
        }
        precondition(allowed(), "Writable native editor")
        precondition(allowed(kAXTextFieldRole, text: false, value: true), "Writable input")
        precondition(!allowed(kAXStaticTextRole), "Selectable text is not editable")
        precondition(!allowed(kAXButtonRole), "Buttons cannot dictate")
        precondition(!allowed(editable: false), "Explicitly read-only wins over setter claims")
        precondition(!allowed(enabled: false), "Disabled target rejected")
        precondition(allowed(enabled: nil), "Writable editors need not expose AXEnabled")
        precondition(allowed(editable: true, range: false, text: false), "Explicitly editable web input")
        precondition(!allowed(secure: true), "Password field rejected")
        precondition(!allowed(range: false), "No insertion position rejected")
        precondition(!allowed(text: false, value: false), "Selection without a setter rejected")
        print("PASS: editable inputs only; read-only, static, disabled, secure and uncertain targets rejected")
        var hold = DictationHold()
        hold.begin(CGPoint(x: 10, y: 10))
        hold.move(CGPoint(x: 12, y: 13))
        precondition(hold.origin != nil, "Allow small hand movement")
        hold.move(CGPoint(x: 20, y: 10))
        precondition(hold.origin == nil, "Text-selection drag cancels dictation")
        hold.move(CGPoint(x: 10, y: 10))
        precondition(hold.origin == nil, "Returning to the origin must not re-arm")
        hold.begin(.zero); hold.cancel()
        precondition(hold.origin == nil, "Release and Escape cancel pending hold")
        print("PASS: dictation hold tolerates jitter, rejects drags, and stays cancelled")
    }
}
