import AppKit
import Combine
import EventKit
import SwiftUI

/// Keep EventKit's source/subscription cache alive. All access stays on this serial queue.
private final class CalendarEventReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.telos.calendar", qos: .userInitiated)
    private var store: EKEventStore?
    func read(start: Date, end: Date, completion: @escaping ([CalendarEntry]) -> Void) {
        queue.async {
            if self.store == nil { self.store = EKEventStore() }
            guard let ek = self.store else { return }
            ek.refreshSourcesIfNecessary()
            let predicate = ek.predicateForEvents(withStart: start, end: end, calendars: ek.calendars(for: .event))
            let values = ek.events(matching: predicate).filter { event in
                event.status != .canceled && !(event.attendees ?? []).contains { $0.isCurrentUser && $0.participantStatus == .declined }
            }.compactMap { event -> CalendarEntry? in
                guard let begin = event.startDate, let finish = event.endDate, finish > begin else { return nil }
                return CalendarEntry(id: "\(event.calendar.calendarIdentifier):\(event.eventIdentifier ?? event.calendarItemIdentifier):\(begin.timeIntervalSince1970)", title: event.title?.isEmpty == false ? event.title! : "Untitled event", start: begin, end: finish, allDay: event.isAllDay)
            }
            completion(values)
        }
    }
}

@MainActor final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()
    @Published private(set) var events: [CalendarEntry] = []
    @Published private(set) var authorized = false
    @Published private(set) var requesting = false
    @Published private(set) var status = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var now = Date()
    @Published private(set) var error: String?
    private let eventStore = EKEventStore()
    private let reader = CalendarEventReader()
    private var subscriptions = Set<AnyCancellable>()
    private var generation = 0
    private var loading = false
    private var refreshPending = false
    private let preview = ProcessInfo.processInfo.environment["TELOS_PREVIEW"] != nil
    var days: [CalendarDay] { CalendarSchedule.days(events, now: now) }
    var nextEvent: CalendarEntry? { CalendarSchedule.next(events, now: now) }
    init() {
        if preview {
            authorized = true
            let today = Calendar.current.startOfDay(for: now)
            events = [CalendarEntry(id: "holiday", title: "中秋节（休）", start: Calendar.current.date(byAdding: .day, value: -1, to: today)!, end: Calendar.current.date(byAdding: .day, value: 2, to: today)!, allDay: true),
                      CalendarEntry(id: "meeting", title: "1on1 meeting with 抗", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(5400), allDay: false)]
            for offset in [1, 2, 4, 6] {
                let day = Calendar.current.date(byAdding: .day, value: offset, to: today)!
                events.append(CalendarEntry(id: "meeting-\(offset)", title: "Zoom Slides design review", start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(10 * 3600), allDay: false))
            }
            let mode = ProcessInfo.processInfo.environment["TELOS_PREVIEW"]
            if mode == "calendar-empty" { events = [] }
            if mode == "calendar-permission" || mode == "calendar-denied" {
                events = []; authorized = false; status = mode == "calendar-denied" ? .denied : .notDetermined
            }
            return
        }
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: nil)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        for name in [NSApplication.didBecomeActiveNotification, .NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }
    func requestAccess() {
        guard !requesting else { return }
        requesting = true; error = nil
        eventStore.requestFullAccessToEvents { [weak self] _, failure in
            Task { @MainActor in
                guard let self else { return }
                self.requesting = false
                self.error = failure?.localizedDescription
                self.refresh()
            }
        }
    }
    func refresh() {
        guard !preview else { return }
        now = Date()
        status = EKEventStore.authorizationStatus(for: .event)
        authorized = status == .fullAccess
        guard authorized else { generation += 1; events = []; return }
        guard !loading else { refreshPending = true; return }
        loading = true; generation += 1
        let token = generation, start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        // Include recently started multi-day subscriptions, then clip display to the seven-day window.
        let fetchStart = Calendar.current.date(byAdding: .day, value: -31, to: start)!
        reader.read(start: fetchStart, end: end) { [weak self] values in
            Task { @MainActor in
                guard let self else { return }
                self.loading = false
                defer {
                    if self.refreshPending {
                        self.refreshPending = false
                        self.refresh()
                    }
                }
                guard token == self.generation, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
                self.events = values
            }
        }
    }
    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }
}

