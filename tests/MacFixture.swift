import AppKit
@MainActor final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var output: NSTextField!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 80, y: 160, width: 680, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Telos Harness Fixture — local test only"
        let view = NSView(frame: NSRect(x: 0,y: 0,width: 680,height: 360))
        let title = NSTextField(labelWithString: "Local test: no email or network actions")
        title.frame = NSRect(x: 32,y: 295,width: 610,height: 24); view.addSubview(title)
        output = NSTextField(labelWithString: "Nothing sent")
        output.setAccessibilityIdentifier("fixtureStatus")
        output.frame = NSRect(x: 32,y: 240,width: 610,height: 24); view.addSubview(output)
        let button = NSButton(title: "Send Test Message", target: self, action: #selector(sendTest))
        button.frame = NSRect(x: 32,y: 160,width: 200,height: 36); view.addSubview(button)
        window.contentView = view; window.orderBack(nil)
        write("Nothing sent")
    }
    @objc func sendTest() { output.stringValue = "Sent test message"; write("Sent test message") }
    func write(_ status: String) {
        guard let path=ProcessInfo.processInfo.environment["TELOS_FIXTURE_STATE"] else { return }
        try? status.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
@main struct Fixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = FixtureDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run(); _ = delegate
    }
}
