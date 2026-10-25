import Foundation

@main struct PicoProactivityTests {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func clock(_ hour: Int, _ minute: Int = 0, day: Int = 24) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
        }
        let now = clock(10)
        func todo(_ title: String, due: String? = nil, status: String = "ready") -> Todo {
            var t = Todo(title: title); t.status = status; t.dueDate = due; return t
        }
        func event(_ id: String, start: Date) -> ZoomCalendarEventValue {
            ZoomCalendarEventValue(id: id, title: id, start: start.timeIntervalSince1970,
                                   end: start.addingTimeInterval(3600).timeIntervalSince1970, allDay: false)
        }
        func snapshot(_ values: [ZoomCalendarEventValue], at: Date, scope: String = "account-A|UTC") -> PicoCalendarSnapshot {
            PicoCalendarSnapshot(scope: scope, synchronizedAt: at, events: values)
        }
        // Existing stale work establishes a quiet baseline; newly due work is important.
        var rules = PicoProactiveRules()
        var old = todo("Old overdue", due: "2026-10-23")
        var upcoming = todo("Tomorrow", due: "2026-10-25")
        var run = todo("Running", status: "running")
        rules.observeTasks([old, upcoming, run], now: now, calendar: calendar)
        precondition(rules.pending.isEmpty)
        rules.observeTasks([old, upcoming, run], now: now.addingTimeInterval(60), calendar: calendar)
        precondition(rules.pending.isEmpty)
        let newlyDue = todo("New due", due: "2026-10-24")
        rules.observeTasks([old, upcoming, run, newlyDue], now: now, calendar: calendar)
        precondition(rules.pending.count == 1 && rules.pending[0].kind == "task-due")
        let dueID = rules.pending[0].id
        let encoded = try JSONEncoder().encode(rules)
        var reopened = try JSONDecoder().decode(PicoProactiveRules.self, from: encoded)
        precondition(reopened.pending[0].id == dueID, "Pending IDs survive restart to deduplicate Chat writes")
        let delivered = reopened.next(now: now, calendar: calendar)!
        reopened.delivered(delivered, now: now, calendar: calendar)
        reopened.observeTasks([old, upcoming, run, newlyDue], now: now.addingTimeInterval(1200), calendar: calendar)
        precondition(reopened.pending.isEmpty, "A due date is only announced once, including after reload")
        run.status = "needs_input"; run.messages = [Message(role: "assistant", text: "Question")]
        reopened.observeTasks([old, upcoming, run], now: now.addingTimeInterval(1200), calendar: calendar)
        precondition(reopened.pending.count == 1 && reopened.pending[0].kind == "task-status")
        run.status = "ready"
        reopened.observeTasks([old, upcoming, run], now: now.addingTimeInterval(1210), calendar: calendar)
        precondition(reopened.pending.isEmpty, "Resolved tasks must not leave stale queued reminders")
        old.status = "completed"; upcoming.dueDate = "2026-02-30"
        reopened.observeTasks([old, upcoming], now: now, calendar: calendar)
        precondition(reopened.pending.isEmpty)
        precondition(PicoProactiveRules.due("2026-02-30", calendar: calendar) == nil)
        precondition(PicoProactiveRules.due("2026-2-3", calendar: calendar) == nil)
        precondition(PicoProactiveRules.due("2026-10-25", calendar: calendar) != nil)
        // A task crossing midnight is detected, without treating elapsed time as approval.
        var midnight = PicoProactiveRules()
        let tomorrow = todo("Due tomorrow", due: "2026-10-25")
        midnight.observeTasks([tomorrow], now: clock(21), calendar: calendar)
        midnight.observeTasks([tomorrow], now: clock(8, day: 25), calendar: calendar)
        precondition(midnight.pending.count == 1)
        // Only a complete same-account snapshot may declare cancellation or rescheduling.
        var meetings = PicoProactiveRules()
        let first = event("A", start: now.addingTimeInterval(3600))
        meetings.observeCalendar(snapshot([first], at: now), now: now)
        precondition(meetings.pending.isEmpty)
        meetings.observeCalendar(snapshot([], at: now.addingTimeInterval(60), scope: "account-B|UTC"), now: now.addingTimeInterval(60))
        precondition(meetings.pending.isEmpty, "Account changes establish a new baseline")
        meetings.observeCalendar(snapshot([first], at: now.addingTimeInterval(120), scope: "account-B|UTC"), now: now.addingTimeInterval(120))
        let shifted = event("A", start: now.addingTimeInterval(4200))
        meetings.observeCalendar(snapshot([shifted], at: now.addingTimeInterval(180), scope: "account-B|UTC"), now: now.addingTimeInterval(180))
        precondition(meetings.pending.count == 1 && meetings.pending[0].kind == "meeting-change")
        meetings.observeCalendar(snapshot([shifted], at: now.addingTimeInterval(240), scope: "account-B|UTC"), now: now.addingTimeInterval(240))
        precondition(meetings.pending.count == 1)
        meetings.observeCalendar(snapshot([], at: now.addingTimeInterval(300), scope: "account-B|UTC"), now: now.addingTimeInterval(300))
        precondition(meetings.pending.count == 1 && meetings.pending[0].kind == "meeting-cancel",
                     "A cancellation supersedes an undelivered reschedule")
        meetings.observeCalendar(snapshot([shifted], at: now.addingTimeInterval(360), scope: "account-B|UTC"), now: now.addingTimeInterval(360))
        precondition(meetings.pending.isEmpty, "A restored meeting invalidates a queued cancellation")
        // Old/failed caches never produce the ten-minute reminder.
        var stale = PicoProactiveRules()
        stale.observeCalendar(snapshot([event("Soon", start: now.addingTimeInterval(300))], at: now.addingTimeInterval(-3600)), now: now)
        precondition(stale.pending.isEmpty)
        stale.observeCalendar(snapshot([event("Soon", start: now.addingTimeInterval(300))], at: now), now: now)
        precondition(stale.pending.count == 1)
        stale.updateUpcoming(now: now.addingTimeInterval(60))
        precondition(stale.pending.count == 1)
        stale.updateUpcoming(now: now.addingTimeInterval(301))
        precondition(stale.pending.isEmpty, "Late wake must not announce a meeting already started")
        // Quiet hours, spacing and the three-per-day ceiling are independent controls.
        var capped = PicoProactiveRules()
        capped.observeTasks([], now: clock(21), calendar: calendar)
        let items = (0..<5).map { todo("Due \($0)", due: "2026-10-24") }
        capped.observeTasks(items, now: clock(21), calendar: calendar)
        precondition(capped.next(now: clock(22), calendar: calendar) == nil)
        precondition(capped.next(now: clock(7), calendar: calendar) == nil)
        let one = capped.next(now: clock(21), calendar: calendar)!
        capped.delivered(one, now: clock(21), calendar: calendar)
        precondition(capped.next(now: clock(21, 9), calendar: calendar) == nil)
        let two = capped.next(now: clock(21, 10), calendar: calendar)!
        capped.delivered(two, now: clock(21, 10), calendar: calendar)
        let three = capped.next(now: clock(21, 20), calendar: calendar)!
        capped.delivered(three, now: clock(21, 20), calendar: calendar)
        precondition(capped.next(now: clock(21, 30), calendar: calendar) == nil)
        precondition(capped.next(now: clock(8, day: 25), calendar: calendar) != nil)
        print("Pico proactivity isolated rules passed")
    }
}
