import ApplicationServices
import CoreGraphics
import Foundation

/// Pure screen-recording rules: coordinate spaces, output naming and the Option+R typing exception.
enum ScreenRecordingRules {
    /// AppKit global rect (bottom-left origin) → display-local, top-left points used by ScreenCaptureKit.
    static func sourceRect(_ rect: CGRect, screenFrame: CGRect) -> CGRect {
        let clipped = rect.intersection(screenFrame)
        guard !clipped.isNull else { return .zero }
        return CGRect(x: clipped.minX - screenFrame.minX, y: screenFrame.maxY - clipped.maxY,
                      width: clipped.width, height: clipped.height)
    }
    /// Window-server bounds (top-left of the primary display) → AppKit global.
    static func appKitRect(windowBounds rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
    /// H.264 encodes even dimensions only.
    static func pixels(_ points: CGFloat, scale: CGFloat) -> Int { max(2, Int((points * scale).rounded()) / 2 * 2) }

    static let minimumSide: CGFloat = 16
    static func isDrag(from start: CGPoint, to end: CGPoint) -> Bool { hypot(end.x - start.x, end.y - start.y) > 4 }
    /// A drag never leaves the display it started on.
    static func dragRect(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect {
        func clamp(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY)) }
        let a = clamp(start), b = clamp(end)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    static func isUsableArea(_ rect: CGRect) -> Bool { rect.width >= minimumSide && rect.height >= minimumSide }

    /// Centre a bar on a rect while keeping it fully on screen.
    static func barOrigin(size: CGSize, centeredIn rect: CGRect, screen: CGRect) -> CGPoint {
        let x = min(max(rect.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        let y = min(max(rect.midY - size.height / 2, screen.minY), screen.maxY - size.height)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// The recording is named after its start time, e.g. "2026-10-14 15.30.12.mp4" (Finder shows ":" as "/").
    static func fileName(startedAt date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: date) + ".mp4"
    }
    static func availableURL(named name: String, in directory: URL,
                             exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = directory.appendingPathComponent(name)
        guard exists(first) else { return first }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        for index in 2... {
            let candidate = directory.appendingPathComponent("\(base) \(index)").appendingPathExtension(ext)
            if !exists(candidate) { return candidate }
        }
        return first
    }
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds)), hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// Option+R types ® while a text caret is active, so the shortcut only records elsewhere.
    /// Password fields count as text: the keystroke belongs to the user there too.
    static func acceptsTyping(role: String, editable: Bool?, enabled: Bool?) -> Bool {
        guard enabled != false, editable != false else { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) || editable == true
    }
}
