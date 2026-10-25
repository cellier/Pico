import AppKit
import Combine
import Foundation

struct ZoomCalendarBinding: Equatable, Sendable {
    let enabled: Bool
    let connectionID: String?
}

struct ZoomCalendarEventValue: Codable, Sendable {
    let id: String
    let title: String
    let start: Double
    let end: Double
    let allDay: Bool
    var entry: CalendarEntry { CalendarEntry(id: id, title: title, start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end), allDay: allDay) }
}

struct ZoomCalendarResponse: Decodable, Sendable {
    let source: String
    let state: String
    let message: String
    let events: [ZoomCalendarEventValue]
    let complete: Bool
    let connection_id: String?
    let account_id: String?
}

struct ZoomCalendarCache: Codable, Sendable {
    let connectionID: String
    let accountID: String
    let timeZone: String
    let updated: Date
    let events: [ZoomCalendarEventValue]
}

protocol ZoomCalendarReading: Sendable {
    func binding(directory: URL) async -> ZoomCalendarBinding
    func read(directory: URL, start: Date, end: Date, timeZone: String) async throws -> ZoomCalendarResponse
    func cached(directory: URL) async -> ZoomCalendarCache?
    func save(_ cache: ZoomCalendarCache?, directory: URL) async
}

/// Local metadata and cache IO stay off the main actor. Account credentials
/// remain in DevHelper; only normalized Zoom calendar events are cached here.
actor ZoomCalendarReader: ZoomCalendarReading {
    func binding(directory: URL) -> ZoomCalendarBinding {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("zoom-connection.json")),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ZoomCalendarBinding(enabled: false, connectionID: nil)
        }
        return ZoomCalendarBinding(enabled: settings["enabled"] as? Bool == true,
                                   connectionID: settings["connection_id"] as? String)
    }
    func read(directory: URL, start: Date, end: Date, timeZone: String) async throws -> ZoomCalendarResponse {
        guard let python = BundledRuntime.python(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/zoom_calendar.py"),
              FileManager.default.fileExists(atPath: script.path) else { throw ZoomConnectionCommand.Failure.missingRuntime }
        let formatter = ISO8601DateFormatter()
        let bytes = try await ZoomConnectionCommand.run(executable: python,
            arguments: ["-B", script.path, "--start", formatter.string(from: start), "--end", formatter.string(from: end), "--timezone", timeZone],
            directory: directory, timeout: 90)
        guard let result = try? JSONDecoder().decode(ZoomCalendarResponse.self, from: bytes) else {
            throw ZoomConnectionCommand.Failure.invalidResponse
        }
        return result
    }
    func cached(directory: URL) -> ZoomCalendarCache? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("zoom-events-cache.json")) else { return nil }
        return try? JSONDecoder().decode(ZoomCalendarCache.self, from: data)
    }
    func save(_ cache: ZoomCalendarCache?, directory: URL) {
        let url = directory.appendingPathComponent("zoom-events-cache.json")
        guard let cache else { try? FileManager.default.removeItem(at: url); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Sync remains useful if an optional local cache cannot be saved. */ }
    }
}

/// A complete, identity-verified result. Cached or failed reads never emit one.
struct PicoCalendarSnapshot: Codable, Equatable {
    let scope: String
    let synchronizedAt: Date
    let events: [ZoomCalendarEventValue]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope && lhs.synchronizedAt == rhs.synchronizedAt
    }
}

@MainActor final class CalendarStore: ObservableObject {
    static let shared = CalendarStore()
    @Published private(set) var events: [CalendarEntry] = []
    @Published private(set) var authorized = false
    @Published private(set) var requesting = false
    @Published private(set) var status = "loading"
    @Published private(set) var now = Date()
    @Published private(set) var error: String?
    @Published private(set) var successfulSnapshot: PicoCalendarSnapshot?
    @Published private(set) var lastSuccessfulSync: Date?
    private let directory: URL
    private let reader: any ZoomCalendarReading
    private var subscriptions = Set<AnyCancellable>()
    private var generation = 0
    private var binding: ZoomCalendarBinding?
    private var cacheLoaded = false
    private var candidateCache: ZoomCalendarCache?
    private var accountID: String?
    private var refreshTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var refreshPending = false
    private var lastAttempt: Date?
    private let preview: Bool
    var days: [CalendarDay] { CalendarSchedule.days(events, now: now) }
    var nextEvent: CalendarEntry? { CalendarSchedule.next(events, now: now) }
    var needsSignIn: Bool { ["needs_login", "auth_required", "authentication_required", "expired"].contains(status) }

    init(directory: URL? = nil, reader: any ZoomCalendarReading = ZoomCalendarReader(),
         automaticallyRefresh: Bool = true,
         previewMode: String? = ProcessInfo.processInfo.environment["TELOS_PREVIEW"]) {
        self.directory = directory ?? ProcessInfo.processInfo.environment["TELOS_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telos")
        self.reader = reader
        preview = previewMode != nil
        if let mode = previewMode {
            authorized = true; status = "connected"
            let today = Calendar.current.startOfDay(for: now)
            events = [CalendarEntry(id: "holiday", title: "中秋节（休）", start: Calendar.current.date(byAdding: .day, value: -1, to: today)!, end: Calendar.current.date(byAdding: .day, value: 2, to: today)!, allDay: true),
                      CalendarEntry(id: "meeting", title: "1on1 meeting with 抗", start: now.addingTimeInterval(1800), end: now.addingTimeInterval(5400), allDay: false)]
            for offset in [1, 2, 4, 6] {
                let day = Calendar.current.date(byAdding: .day, value: offset, to: today)!
                events.append(CalendarEntry(id: "meeting-\(offset)", title: "Zoom Slides design review", start: day.addingTimeInterval(9 * 3600), end: day.addingTimeInterval(10 * 3600), allDay: false))
            }
            if mode == "calendar-empty" { events = [] }
            if mode == "calendar-permission" || mode == "calendar-denied" { events = []; authorized = false; status = "disconnected" }
            return
        }
        guard automaticallyRefresh else { return }
        NotificationCenter.default.publisher(for: .picoZoomConnectionChanged)
            .receive(on: RunLoop.main).sink { [weak self] notification in
                guard let self, notification.userInfo?["directory"] as? String == self.directory.path else { return }
                self.connectionChanged(state: notification.userInfo?["state"] as? String,
                                       message: notification.userInfo?["message"] as? String)
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.connectionChanged() }.store(in: &subscriptions)
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh(force: true) }.store(in: &subscriptions)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }.store(in: &subscriptions)
        refresh()
    }

    /// Called when Pico's existing Zoom connection changes; invalidate immediately
    /// so an old request cannot publish another account's calendar afterward.
    func connectionChanged(state: String? = nil, message: String? = nil) {
        generation += 1; binding = nil; cacheLoaded = false; lastAttempt = nil
        events = []; authorized = false; lastSuccessfulSync = nil; successfulSnapshot = nil
        status = state ?? "loading"; error = state == "connected" ? nil : message
        accountID = nil; candidateCache = nil
        refresh(force: true)
    }
    func requestAccess() {
        guard connectionTask == nil else { return }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            self.requesting = true
            let model = ZoomConnectionModel(directory: self.directory)
            if self.needsSignIn { await model.signIn() }
            else { await model.perform("connect") }
            self.connectionTask = nil
            self.connectionChanged(state: model.status.state, message: model.error ?? model.status.message)
            self.error = model.error ?? (model.status.connected ? nil : model.status.message)
            self.requesting = self.refreshTask != nil

        }
    }
    func refresh(force: Bool = false) {
        guard !preview else { return }
        now = Date()
        if refreshTask != nil { refreshPending = refreshPending || force; return }
        requesting = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.synchronize(force: force)
            self.refreshTask = nil
            self.requesting = self.connectionTask != nil
            if self.refreshPending {
                self.refreshPending = false
                self.refresh(force: true)
            }
        }
    }
    private func synchronize(force: Bool) async {
        let initialGeneration = generation
        let current = await reader.binding(directory: directory)
        guard initialGeneration == generation else { return }
        if binding != current {
            generation += 1; binding = current; cacheLoaded = false; lastAttempt = nil
            events = []; authorized = false; lastSuccessfulSync = nil; successfulSnapshot = nil
            accountID = nil; candidateCache = nil
        }
        let token = generation
        guard current.enabled, let connectionID = current.connectionID, !connectionID.isEmpty else {
            if !needsSignIn { status = "disconnected"; error = nil }
            authorized = false
            await reader.save(nil, directory: directory)
            return
        }
        let zone = TimeZone.current.identifier
        if !cacheLoaded {
            cacheLoaded = true
            let saved = await reader.cached(directory: directory)
            guard token == generation else { return }
            // A Pico connection ID alone does not identify DevHelper's account.
            // Keep the cache private until this request confirms its account.
            if saved?.connectionID == connectionID && saved?.timeZone == zone { candidateCache = saved }

        }
        guard token == generation else { return }
        // Returning to the window should update the clock and connection state,
        // without issuing another full calendar query on every activation.
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < 50 { return }
        lastAttempt = Date()
        let clock = Date(), calendar = Calendar.current
        let start = calendar.startOfDay(for: clock)
        guard let end = calendar.date(byAdding: .day, value: 7, to: start) else { return }
        do {
            let response = try await reader.read(directory: directory, start: start, end: end, timeZone: zone)
            let latest = await reader.binding(directory: directory)
            guard token == generation else { return }
            guard latest == current else { connectionChanged(); return }
            guard response.source == "zoom" else { throw ZoomConnectionCommand.Failure.invalidResponse }
            // Reject mismatched connection generations before loading even a
            // matching account's cache from an obsolete response.
            if let responseConnection = response.connection_id, responseConnection != connectionID {
                throw ZoomConnectionCommand.Failure.invalidResponse
            }
            if ["disconnected", "needs_login", "auth_required", "authentication_required", "expired"].contains(response.state) {
                events = []; authorized = false; lastSuccessfulSync = nil; successfulSnapshot = nil; accountID = nil; candidateCache = nil
                status = response.state; error = response.message
                await reader.save(nil, directory: directory)
                return
            }
            guard let identity = response.account_id, !identity.isEmpty else {
                if accountID == nil || lastSuccessfulSync == nil {
                    events = []; authorized = false; lastSuccessfulSync = nil
                }
                status = response.state
                error = response.message.isEmpty ? "Could not verify your Zoom calendar account. Please try again." : response.message
                return
            }
            if accountID != identity {
                accountID = identity; events = []; lastSuccessfulSync = nil; authorized = false
                if let saved = candidateCache, saved.accountID == identity {
                    events = saved.events.map(\.entry); lastSuccessfulSync = saved.updated; authorized = true
                } else if candidateCache != nil {
                    candidateCache = nil
                    await reader.save(nil, directory: directory)
                    guard token == generation else { return }
                }
            }
            guard response.state == "connected", response.complete, response.connection_id == connectionID else {
                status = response.state
                error = response.message.isEmpty ? "Could not sync your Zoom events. Please try again." : response.message
                authorized = lastSuccessfulSync != nil
                return
            }
            var seen = Set<String>()
            let valid = response.events.filter { $0.start.isFinite && $0.end.isFinite && $0.end > $0.start && seen.insert($0.id).inserted }
            events = valid.map(\.entry)
            now = Date(); authorized = true; status = "connected"; error = nil; lastSuccessfulSync = now
            let saved = ZoomCalendarCache(connectionID: connectionID, accountID: identity, timeZone: zone, updated: now, events: valid)
            candidateCache = saved
            await reader.save(saved, directory: directory)
            guard token == generation else { return }
            successfulSnapshot = PicoCalendarSnapshot(scope: connectionID + "|" + identity + "|" + zone,
                                                       synchronizedAt: now, events: valid)
        } catch {
            let latest = await reader.binding(directory: directory)
            guard token == generation else { return }
            guard latest == current else { connectionChanged(); return }
            status = "unavailable"
            self.error = (error as? ZoomConnectionCommand.Failure)?.localizedDescription ?? "Could not sync your Zoom events. Please try again."
            // An identity-verified, unchanged connection may keep its last-good
            // data during a transient outage. Cold-start caches remain private.
            if accountID == nil || lastSuccessfulSync == nil {
                events = []; authorized = false; lastSuccessfulSync = nil
            }

        }
    }
}
