import CoreGraphics
@main struct TelosKeyboardEventTests {
    static func main() {
        for down in [true, false] {
            let manual = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: down)!
            manual.flags = .maskCommand
            precondition(TelosKeyboardEvent.shouldDisplay(manual))
            let automatic = manual.copy()!
            TelosKeyboardEvent.markDictationPaste(automatic)
            precondition(!TelosKeyboardEvent.shouldDisplay(automatic))
            precondition(automatic.flags == manual.flags)
            precondition(automatic.getIntegerValueField(.keyboardEventKeycode) == 9)
            let propagated = automatic.copy()!
            precondition(!TelosKeyboardEvent.shouldDisplay(propagated))
            precondition(TelosKeyboardEvent.shouldDisplay(manual))
        }
        print("PASS: generated paste filtered on down/up, tag survives event copy, manual paste preserved")
    }
}
