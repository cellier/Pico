import Foundation

/// Successful daily checks follow the local calendar; failed attempts retry after 15 minutes.
enum FeedSchedule {
    static func isDue(intervalMinutes: Int, lastRefresh: Double, lastAttempt: Double,
                      now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard intervalMinutes > 0 else { return false }
        let timestamp = now.timeIntervalSince1970
        guard lastAttempt <= 0 || timestamp - lastAttempt >= 15 * 60 else { return false }
        guard lastRefresh > 0 else { return true }
        if intervalMinutes == 1440 {
            return calendar.startOfDay(for: Date(timeIntervalSince1970: lastRefresh)) < calendar.startOfDay(for: now)
        }
        return timestamp - lastRefresh >= Double(intervalMinutes) * 60
    }
}
