import Foundation
@main struct FeedScheduleTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let now = date("2026-09-28T08:00:00+08:00")
        func due(_ refresh: String, attempt: Double = 0, interval: Int = 1440) -> Bool {
            FeedSchedule.isDue(intervalMinutes: interval, lastRefresh: date(refresh).timeIntervalSince1970,
                               lastAttempt: attempt, now: now, calendar: calendar)
        }
        precondition(due("2026-09-27T23:50:00+08:00"))
        precondition(!due("2026-09-28T00:01:00+08:00"))
        precondition(due("2026-09-25T08:00:00+08:00"))
        precondition(!due("2026-09-27T08:00:00+08:00", attempt: now.timeIntervalSince1970 - 899))
        precondition(due("2026-09-27T08:00:00+08:00", attempt: now.timeIntervalSince1970 - 900))
        precondition(!due("2026-09-27T08:00:00+08:00", interval: 0))
        precondition(!due("2026-09-28T07:45:00+08:00", interval: 60))
        precondition(due("2026-09-28T07:00:00+08:00", interval: 60))
        let stamp = now.timeIntervalSince1970
        precondition(FeedSchedule.isDue(intervalMinutes: 1440, lastRefresh: stamp, lastAttempt: stamp - 901, now: now, status: "partial", nextRetry: stamp - 1))
        precondition(!FeedSchedule.isDue(intervalMinutes: 1440, lastRefresh: 0, lastAttempt: stamp - 901, now: now, status: "failed", nextRetry: stamp + 900))
        precondition(!FeedSchedule.isDue(intervalMinutes: 1440, lastRefresh: 0, lastAttempt: stamp - 901, now: now, status: "running"))
        precondition(FeedSchedule.isDue(intervalMinutes: 1440, lastRefresh: 0, lastAttempt: stamp - 1201, now: now, status: "running"))
        print("PASS: calendar-day refresh, same-day skip, catch-up, failure retry and manual feeds")
    }
}
