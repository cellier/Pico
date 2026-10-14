import AppKit
import ApplicationServices

@main struct ScreenRecordingTests {
    static func main() {
        // AppKit global → ScreenCaptureKit display-local (top-left) points, on primary and secondary displays.
        let primary = CGRect(x: 0, y: 0, width: 1512, height: 982)
        precondition(ScreenRecordingRules.sourceRect(CGRect(x: 100, y: 200, width: 300, height: 400), screenFrame: primary)
            == CGRect(x: 100, y: 382, width: 300, height: 400))
        let secondary = CGRect(x: 1512, y: -100, width: 1920, height: 1080)
        precondition(ScreenRecordingRules.sourceRect(CGRect(x: 1612, y: 0, width: 200, height: 100), screenFrame: secondary)
            == CGRect(x: 100, y: 880, width: 200, height: 100))
        precondition(ScreenRecordingRules.sourceRect(primary, screenFrame: primary) == CGRect(origin: .zero, size: primary.size))
        // Areas crossing a display edge are clipped to that display.
        precondition(ScreenRecordingRules.sourceRect(CGRect(x: 1400, y: 0, width: 300, height: 100), screenFrame: primary).width == 112)
        // Window-server bounds are top-left of the primary display.
        precondition(ScreenRecordingRules.appKitRect(windowBounds: CGRect(x: 10, y: 20, width: 300, height: 200), primaryHeight: 982)
            == CGRect(x: 10, y: 762, width: 300, height: 200))
        // H.264 needs even pixel dimensions.
        precondition(ScreenRecordingRules.pixels(301, scale: 1) % 2 == 0)
        precondition(ScreenRecordingRules.pixels(300.5, scale: 2) == 600)
        precondition(ScreenRecordingRules.pixels(0, scale: 2) == 2)
        // Drag: any direction, clamped to the starting display, small moves are clicks.
        precondition(ScreenRecordingRules.dragRect(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 100, y: 50), within: primary)
            == CGRect(x: 100, y: 50, width: 300, height: 250))
        precondition(ScreenRecordingRules.dragRect(from: CGPoint(x: 1400, y: 900), to: CGPoint(x: 1700, y: 1200), within: primary)
            == CGRect(x: 1400, y: 900, width: 112, height: 82))
        precondition(!ScreenRecordingRules.isDrag(from: .zero, to: CGPoint(x: 3, y: 2)))
        precondition(ScreenRecordingRules.isDrag(from: .zero, to: CGPoint(x: 5, y: 0)))
        precondition(!ScreenRecordingRules.isUsableArea(CGRect(x: 0, y: 0, width: 200, height: 10)))
        // The setup bar centres on the selection but never leaves the display.
        let size = CGSize(width: 320, height: 86)
        precondition(ScreenRecordingRules.barOrigin(size: size, centeredIn: CGRect(x: 100, y: 100, width: 400, height: 300), screen: primary)
            == CGPoint(x: 140, y: 207))
        precondition(ScreenRecordingRules.barOrigin(size: size, centeredIn: CGRect(x: 0, y: 0, width: 20, height: 20), screen: primary) == .zero)
        // Name: recording start time, Finder-safe, unique on the Desktop.
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_791_984_612) // 2026-10-14 13:30:12 UTC
        precondition(ScreenRecordingRules.fileName(startedAt: date, timeZone: utc) == "2026-10-14 13.30.12.mp4")
        let desktop = URL(fileURLWithPath: "/tmp/Desktop")
        let taken: Set<String> = ["2026-10-14 13.30.12.mp4", "2026-10-14 13.30.12 2.mp4"]
        precondition(ScreenRecordingRules.availableURL(named: "2026-10-14 13.30.12.mp4", in: desktop) { taken.contains($0.lastPathComponent) }
            .lastPathComponent == "2026-10-14 13.30.12 3.mp4")
        precondition(ScreenRecordingRules.availableURL(named: "a.mp4", in: desktop) { _ in false }.lastPathComponent == "a.mp4")
        // Timer text.
        precondition(ScreenRecordingRules.elapsed(13.9) == "0:13")
        precondition(ScreenRecordingRules.elapsed(725) == "12:05")
        precondition(ScreenRecordingRules.elapsed(3723) == "1:02:03")
        precondition(ScreenRecordingRules.elapsed(-1) == "0:00")
        // Option+R types ® in editable text (including password and rich editors); records elsewhere.
        precondition(ScreenRecordingRules.acceptsTyping(role: kAXTextFieldRole, editable: nil, enabled: nil))
        precondition(ScreenRecordingRules.acceptsTyping(role: kAXTextAreaRole, editable: nil, enabled: true))
        precondition(ScreenRecordingRules.acceptsTyping(role: kAXGroupRole, editable: true, enabled: nil))
        precondition(!ScreenRecordingRules.acceptsTyping(role: kAXTextAreaRole, editable: false, enabled: nil))
        precondition(!ScreenRecordingRules.acceptsTyping(role: kAXTextFieldRole, editable: nil, enabled: false))
        precondition(!ScreenRecordingRules.acceptsTyping(role: kAXButtonRole, editable: nil, enabled: true))
        precondition(!ScreenRecordingRules.acceptsTyping(role: "AXWebArea", editable: nil, enabled: true))
        print("ScreenRecordingTests passed")
    }
}
