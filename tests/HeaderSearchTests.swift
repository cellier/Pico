import AppKit
@main struct HeaderSearchTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(); app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.65)) }
        settle()
        NotificationCenter.default.post(name: .init("TelosSearch"), object: nil)
        settle()
        guard let editor = delegate.window.firstResponder as? NSTextView, editor.isFieldEditor else { fatalError("Search must receive typing focus") }
        editor.insertText("Kickoff", replacementRange: NSRange(location: 0, length: 0)); settle()
        precondition(editor.string == "Kickoff")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: delegate.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        delegate.window.sendEvent(event); settle()
        precondition(delegate.window.firstResponder !== editor, "Escape closes search and releases focus")
        NotificationCenter.default.post(name: .init("TelosSearch"), object: nil); settle()
        guard let reopened = delegate.window.firstResponder as? NSTextView else { fatalError("Reopen search") }
        precondition(reopened.string.isEmpty, "Closing clears the query")
        delegate.window.orderOut(nil)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        print("PASS: search activation, typing, Escape, query clearing and reopen")
    }
}
