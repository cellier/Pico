import AppKit

enum StatusCalendarIcon {
    static let side: CGFloat = 18
    static func symbolName(for date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return "\(calendar.component(.day, from: date)).calendar"
    }

    static func image(for date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> NSImage {
        let name = symbolName(for: date, timeZone: timeZone)
        // Numbered calendars are supplied by the OS; older systems retain a
        // native calendar rather than losing the status-bar entry altogether.
        let source = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "calendar", accessibilityDescription: nil)!
        let image = source.withSymbolConfiguration(.init(pointSize: side, weight: .regular)) ?? source
        image.isTemplate = true
        return image
    }

    static func fittedRect(for image: NSImage, in bounds: NSRect) -> NSRect {
        guard image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
