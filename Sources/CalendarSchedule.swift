import Foundation

struct CalendarEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
}

struct CalendarDay: Identifiable {
    var id: Date { date }
    let date: Date
    let events: [CalendarEntry]
}

enum CalendarSchedule {
    static func days(_ events: [CalendarEntry], now: Date, calendar: Calendar = .current) -> [CalendarDay] {
        let today = calendar.startOfDay(for: now)
        var seen = Set<String>()
        let unique = events.filter { $0.end > now && seen.insert($0.id).inserted }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let rows = unique.filter { $0.start < end && $0.end > day }.sorted {
                if $0.allDay != $1.allDay { return $0.allDay }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
            return rows.isEmpty ? nil : CalendarDay(date: day, events: rows)
        }
    }
    static func next(_ events: [CalendarEntry], now: Date, calendar: Calendar = .current) -> CalendarEntry? {
        guard let day = days(events, now: now, calendar: calendar).first else { return nil }
        return day.events.first(where: { !$0.allDay }) ?? day.events.first
    }
    static func dayTitle(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "EEE MMM d"
        return f.string(from: date)
    }
    static func time(_ event: CalendarEntry) -> String {
        if event.allDay { return "All-day" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "h:mm a"
        return f.string(from: event.start)
    }
    static func menuTitle(_ event: CalendarEntry?, now: Date = .now) -> String? {
        guard let event else { return nil }
        let prefix = Calendar.current.isDate(event.start, inSameDayAs: now) || event.start < now ? "" : dayTitle(event.start, now: now) + " · "
        return prefix + time(event) + " · " + event.title
    }
}

