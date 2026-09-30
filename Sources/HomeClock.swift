import Foundation

/// Keep the compact English design format while following the Mac's time zone.
@MainActor enum HomeClock {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE MMM d HH:mm"
        return formatter
    }()
    static func text(_ date: Date) -> String {
        formatter.timeZone = .autoupdatingCurrent
        return formatter.string(from: date)
    }
}
