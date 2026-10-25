import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

struct PicoProactiveNotice: Codable, Identifiable {
    var id = UUID()
    let key: String
    let text: String
    let created: Date
    let expires: Date
    var kind: String
    var entityID: String
}

/// No model calls or source writes: this state machine only recognizes important changes.
struct PicoProactiveRules: Codable {
    struct TaskBaseline: Codable { var status: String; var due: String? }
    var tasks: [String: TaskBaseline] = [:]
    var taskBaselineEstablished = false
    var calendarScope: String?
    var calendarEvents: [String: ZoomCalendarEventValue] = [:]
    var calendarSync: Date?
    var pending: [PicoProactiveNotice] = []
    var handled: [String: Date] = [:]
    var lastDelivered: Date?
    var deliveryDay = ""
    var deliveriesToday = 0

    static func dateKey(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func due(_ value: String?, calendar: Calendar = .current) -> Date? {
        guard let value, value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar
        f.timeZone = calendar.timeZone; f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: value), f.string(from: date) == value else { return nil }
        return date
    }
    private mutating func enqueue(key: String, text: String, kind: String, entity: String,
                                  now: Date, expires: Date) {
        guard expires > now, handled[key] == nil, !pending.contains(where: { $0.key == key }) else { return }
        pending.append(PicoProactiveNotice(key: key, text: text, created: now, expires: expires,
                                           kind: kind, entityID: entity))
        if pending.count > 80 { pending.removeFirst(pending.count - 80) }
    }
    mutating func observeTasks(_ values: [Todo], now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let byID = Dictionary(values.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { _, last in last })
        pending.removeAll { notice in
            guard notice.kind.hasPrefix("task"), let item = byID[notice.entityID] else { return notice.kind.hasPrefix("task") }
            if item.status == "completed" { return true }
            if notice.kind == "task-status" { return !["error", "needs_input"].contains(item.status) }
            return !notice.key.hasSuffix("|" + (item.dueDate ?? ""))
        }
        for task in values {
            let id = task.id.uuidString, previous = tasks[id]
            if taskBaselineEstablished, previous?.status == "running", ["needs_input", "error"].contains(task.status) {
                let version = task.messages.last?.id.uuidString ?? task.activeRunID?.uuidString ?? "state"
                let text = task.status == "error" ? "“\(task.title)”遇到了问题，需要你看一下。" : "“\(task.title)”需要你的补充，打开任务就能继续。"
                enqueue(key: "task-status|" + id + "|" + task.status + "|" + version,
                        text: text, kind: "task-status", entity: id, now: now, expires: now.addingTimeInterval(24 * 3600))
            }
            if task.status != "completed", let due = Self.due(task.dueDate, calendar: calendar), due <= today {
                let key = "task-due|" + id + "|" + (task.dueDate ?? "")
                if !taskBaselineEstablished { handled[key] = now }
                else {
                    let wording = due == today ? "今天到期" : "已经过期"
                    enqueue(key: key, text: "“\(task.title)”\(wording)，还没有完成。", kind: "task-due", entity: id,
                            now: now, expires: now.addingTimeInterval(24 * 3600))
                }
            }
            tasks[id] = TaskBaseline(status: task.status, due: task.dueDate)
        }
        tasks = tasks.filter { byID[$0.key] != nil }
        taskBaselineEstablished = true
        prune(now: now)
    }
    mutating func observeCalendar(_ snapshot: PicoCalendarSnapshot, now: Date) {
        guard snapshot.synchronizedAt <= now.addingTimeInterval(60),
              now.timeIntervalSince(snapshot.synchronizedAt) <= 15 * 60 else { return }
        let next = Dictionary(snapshot.events.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        // A later successful read supersedes queued information before delivery.
        pending.removeAll { notice in
            if notice.kind == "meeting-cancel" { return next[notice.entityID] != nil }
            if notice.kind == "meeting-change" {
                guard let current = next[notice.entityID] else { return true }
                return !notice.key.hasSuffix("|" + String(current.start))
            }
            return false
        }
        if calendarScope == snapshot.scope, let previousSync = calendarSync, snapshot.synchronizedAt > previousSync {
            for old in calendarEvents.values where !old.allDay && old.start > now.timeIntervalSince1970 && old.start <= now.addingTimeInterval(24 * 3600).timeIntervalSince1970 {
                if let changed = next[old.id], !changed.allDay, abs(changed.start - old.start) >= 5 * 60 {
                    let key = "meeting-change|" + snapshot.scope + "|" + old.id + "|" + String(changed.start)
                    let text = "“\(changed.title)”改期了：\(Self.time(Date(timeIntervalSince1970: old.start))) → \(Self.time(Date(timeIntervalSince1970: changed.start)))。"
                    enqueue(key: key, text: text, kind: "meeting-change", entity: old.id, now: now,
                            expires: min(now.addingTimeInterval(24 * 3600), Date(timeIntervalSince1970: changed.start)))
                } else if next[old.id] == nil {
                    enqueue(key: "meeting-cancel|" + snapshot.scope + "|" + old.id + "|" + String(old.start),
                            text: "原定\(Self.time(Date(timeIntervalSince1970: old.start)))的“\(old.title)”已从日历移除。",
                            kind: "meeting-cancel", entity: old.id, now: now, expires: Date(timeIntervalSince1970: old.start))
                }
            }
        } else if calendarScope != snapshot.scope {
            pending.removeAll { $0.kind.hasPrefix("meeting") }
        }
        calendarScope = snapshot.scope; calendarEvents = next; calendarSync = snapshot.synchronizedAt
        pending.removeAll { notice in
            guard notice.kind == "meeting-soon" else { return false }
            guard let current = next[notice.entityID] else { return true }
            return !notice.key.hasSuffix("|" + String(current.start))
        }
        updateUpcoming(now: now)
    }
    mutating func updateUpcoming(now: Date) {
        guard let scope = calendarScope, let synced = calendarSync, now.timeIntervalSince(synced) <= 15 * 60 else { return }
        for event in calendarEvents.values where !event.allDay && event.start > now.timeIntervalSince1970 && event.start <= now.addingTimeInterval(10 * 60).timeIntervalSince1970 {
            enqueue(key: "meeting-soon|" + scope + "|" + event.id + "|" + String(event.start),
                    text: "“\(event.title)”将在\(Self.time(Date(timeIntervalSince1970: event.start)))开始。",
                    kind: "meeting-soon", entity: event.id, now: now, expires: Date(timeIntervalSince1970: event.start))
        }
        prune(now: now)
    }
    mutating func prune(now: Date) {
        pending.removeAll { $0.expires <= now }
        handled = handled.filter { now.timeIntervalSince($0.value) < 90 * 24 * 3600 }
        if handled.count > 5000 {
            handled = Dictionary(uniqueKeysWithValues: handled.sorted { $0.value > $1.value }.prefix(4000).map { ($0.key, $0.value) })
        }
    }
    mutating func next(now: Date, calendar: Calendar = .current, allowMeetings: Bool = true) -> PicoProactiveNotice? {
        prune(now: now)
        let hour = calendar.component(.hour, from: now)
        guard hour >= 8 && hour < 22 else { return nil }
        let day = Self.dateKey(now, calendar: calendar)
        if deliveryDay != day { deliveryDay = day; deliveriesToday = 0 }
        guard deliveriesToday < 3, lastDelivered.map({ now.timeIntervalSince($0) >= 10 * 60 }) ?? true else { return nil }
        return pending.filter { allowMeetings || !$0.kind.hasPrefix("meeting") }.sorted { a, b in a.expires == b.expires ? a.created < b.created : a.expires < b.expires }.first
    }
    mutating func delivered(_ notice: PicoProactiveNotice, now: Date, calendar: Calendar = .current) {
        let day = Self.dateKey(now, calendar: calendar)
        if deliveryDay != day { deliveryDay = day; deliveriesToday = 0 }
        handled[notice.key] = now; pending.removeAll { $0.id == notice.id }; lastDelivered = now; deliveriesToday += 1
    }
    private static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

@MainActor final class PicoProactiveCoordinator: ObservableObject {
    static let enabledKey = "PicoProactivityEnabled"
    static let organizeKey = "PicoOrganizeContext"
    static let appContextKey = "PicoAppContextEnabled"
    static let notificationsKey = "PicoProactiveSystemNotifications"
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: Self.enabledKey); if !enabled { rules.pending = []; workContext = nil; persist() } } }
    @Published var organizeContext: Bool { didSet { defaults.set(organizeContext, forKey: Self.organizeKey) } }
    @Published var appContextEnabled: Bool { didSet { defaults.set(appContextEnabled, forKey: Self.appContextKey); if !appContextEnabled { workContext = nil } else { observeFrontmostApplication() } } }
    @Published private(set) var systemNotifications: Bool
    @Published private(set) var lastOrganizedDate: Date?
    @Published private(set) var settingsMessage: String?
    /// The application also supplies its screen-recording/selection state here.
    var activityIsBusy: () -> Bool = { false }
    private let directory: URL
    private weak var taskStore: TaskStore?
    private let calendar: CalendarStore
    private let defaults: UserDefaults
    private let clock: () -> Date
    private weak var chat: PicoChatStore?
    private var chatActivity: AnyCancellable?
    private var rules = PicoProactiveRules()
    private var subscriptions = Set<AnyCancellable>()
    private var running = false
    private var organizing = false
    private var lastOrganizationAttempt: Date?
    private var workContext: (name: String, bundleID: String?, observed: Date)?
    private var organizationTask: Task<Void, Never>?
    private var notificationGeneration = UUID()
    private var lastPersistedState: Data?
    private var stateURL: URL { directory.appendingPathComponent("proactive-state.json") }

    init(directory: URL, taskStore: TaskStore, calendar: CalendarStore = .shared,
         defaults: UserDefaults = .standard, automaticallyStart: Bool = false,
         clock: @escaping () -> Date = Date.init) {
        self.directory = directory; self.taskStore = taskStore; self.calendar = calendar
        self.defaults = defaults; self.clock = clock
        enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
        organizeContext = defaults.object(forKey: Self.organizeKey) == nil || defaults.bool(forKey: Self.organizeKey)
        appContextEnabled = defaults.bool(forKey: Self.appContextKey)
        systemNotifications = defaults.bool(forKey: Self.notificationsKey)
        if let bytes = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(PicoProactiveRules.self, from: bytes) { rules = saved }
        if let value = defaults.object(forKey: "PicoLastContextOrganization") as? Date { lastOrganizedDate = value }
        if automaticallyStart { start() }
    }
    var requestContext: [String: Any] {
        var value: [String: Any] = ["enabled": enabled, "important_only": true, "organize_context": organizeContext, "app_context_enabled": appContextEnabled]
        if enabled, appContextEnabled, let workContext, clock().timeIntervalSince(workContext.observed) >= 0, clock().timeIntervalSince(workContext.observed) <= 15 * 60 {
            var context: [String: Any] = ["name": workContext.name, "observed_at": ISO8601DateFormatter().string(from: workContext.observed), "meaning": "most recent external app before Pico"]
            if let id = workContext.bundleID { context["bundle_id"] = id }
            value["work_context"] = context
        }
        return value
    }
    func attach(chat: PicoChatStore) {
        if self.chat === chat, chatActivity != nil { evaluate(); return }
        chatActivity?.cancel(); self.chat = chat
        chatActivity = chat.$isRunning.removeDuplicates().sink { [weak self] busy in
            if !busy { self?.evaluate() }
        }
        evaluate()
    }
    func start() {
        guard !running, ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil else { return }
        running = true
        taskStore?.$tasks.debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &subscriptions)
        calendar.$successfulSnapshot.sink { [weak self] snapshot in
            guard let self else { return }
            if let snapshot { self.acceptCalendarSnapshot(snapshot) }
            else {
                self.rules.pending.removeAll { $0.kind.hasPrefix("meeting") }
                self.persist()
            }
        }.store(in: &subscriptions)
        Timer.publish(every: 60, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.evaluate() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.evaluate() }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in self?.observeFrontmostApplication() }.store(in: &subscriptions)
        observeFrontmostApplication(); evaluate()
    }
    func stop() { running = false; subscriptions.removeAll(); chatActivity?.cancel(); chatActivity = nil; organizationTask?.cancel(); organizationTask = nil; persist() }
    func acceptCalendarSnapshot(_ snapshot: PicoCalendarSnapshot) {
        rules.observeCalendar(snapshot, now: clock())
        if !enabled { rules.pending = []; persist(); return }
        persist(); evaluate()
    }
    func evaluate() {
        guard ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil else { return }
        let now = clock()
        // Baselines advance while disabled, so enabling never replays stale changes.
        if let taskStore { rules.observeTasks(taskStore.tasks, now: now) }
        if !enabled { rules.pending = []; persist(); return }
        if !calendar.authorized || calendar.successfulSnapshot == nil {
            rules.pending.removeAll { $0.kind.hasPrefix("meeting") }
        } else if calendar.status == "connected" && calendar.error == nil { rules.updateUpcoming(now: now) }
        else { rules.pending.removeAll { $0.kind == "meeting-soon" } }
        guard persist() else { return }
        organizeIfNeeded(now: now)
        guard !activityIsBusy(), !meetingIsActive(), let chat, !chat.isRunning,
              chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, chat.files.isEmpty,
              let notice = rules.next(now: now, allowMeetings: calendar.authorized && calendar.status == "connected" && calendar.error == nil && calendar.successfulSnapshot != nil) else { return }
        if chat.appendProactiveNotice(id: notice.id, text: notice.text, date: now) {
            rules.delivered(notice, now: now); persist()
            if systemNotifications { notify(notice) }
        }
    }
    private func meetingIsActive() -> Bool {
        if taskStore?.meetings.values.contains(where: { [.preparing, .recording, .finishing].contains($0.status) }) == true { return true }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meeting-status.json")),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["active"] as? Bool == true
    }
    private func observeFrontmostApplication() {
        guard enabled, appContextEnabled, let application = NSWorkspace.shared.frontmostApplication,
              application.bundleIdentifier != Bundle.main.bundleIdentifier,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let name = application.localizedName, !name.isEmpty else { return }
        workContext = (name: String(name.prefix(100)), bundleID: application.bundleIdentifier.map { String($0.prefix(180)) }, observed: clock())
    }
    @discardableResult private func persist() -> Bool {
        guard ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil else { return true }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(rules)
            if data == lastPersistedState,
               let attributes = try? FileManager.default.attributesOfItem(atPath: stateURL.path),
               attributes[.type] as? FileAttributeType == .typeRegular,
               (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 { return true }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: stateURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            lastPersistedState = data
            return true
        } catch { settingsMessage = "Could not save reminder state. Reminders will wait until local storage is available."; return false }
    }
    private func organizeIfNeeded(now: Date) {
        guard enabled, organizeContext, !organizing,
              lastOrganizationAttempt.map({ now.timeIntervalSince($0) >= 10 * 60 }) ?? true,
              let python = BundledRuntime.python(), let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/personal_context.py"),
              FileManager.default.fileExists(atPath: script.path) else { return }
        lastOrganizationAttempt = now; organizing = true
        organizationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.organizing = false; self.organizationTask = nil }
            do {
                let bytes = try await ZoomConnectionCommand.run(executable: python, arguments: ["-B", script.path, "--directory", self.directory.path, "--refresh"], directory: self.directory, timeout: 20)
                guard !Task.isCancelled, self.enabled, self.organizeContext,
                      let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], result["ok"] as? Bool == true,
                      (result["remaining"] as? Int ?? 0) == 0 else { return }
                let reviewed = (result["last_reviewed_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                if let date = reviewed ?? (result["unchanged"] as? Bool == true ? self.lastOrganizedDate : self.clock()) {
                    self.lastOrganizedDate = date; self.defaults.set(date, forKey: "PicoLastContextOrganization")
                }
            } catch { /* Background organization can retry later without interrupting work. */ }
        }
    }
    func setSystemNotifications(_ wanted: Bool) {
        notificationGeneration = UUID(); let generation = notificationGeneration
        guard wanted else { systemNotifications = false; defaults.set(false, forKey: Self.notificationsKey); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self, self.notificationGeneration == generation else { return }
                self.systemNotifications = granted; self.defaults.set(granted, forKey: Self.notificationsKey)
                self.settingsMessage = granted ? nil : "Notifications are off. Pico can still leave important updates in Chat."
            }
        }
    }
    private func notify(_ notice: PicoProactiveNotice) {
        guard !NSApp.isActive else { return }
        let content = UNMutableNotificationContent(); content.title = "Pico"; content.body = notice.text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil)) { _ in }
    }
}

struct PicoProactivitySettings: View {
    @ObservedObject var coordinator: PicoProactiveCoordinator
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Proactivity").font(.system(size: 14, weight: .medium))
            Toggle("Important updates", isOn: $coordinator.enabled)
                .accessibilityIdentifier("picoProactivityEnabled")
            Text("While Pico is running, important meeting changes, upcoming meetings and tasks that need you appear in Chat. Quiet hours: 10 PM–8 AM. At most three updates per day.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("Organize local context", isOn: $coordinator.organizeContext)
                .accessibilityIdentifier("picoOrganizeContext")
            Text("Organizes your messages and task records locally so Pico can look them up later. This private context is not used by the meeting speaker or added to presentation materials.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let date = coordinator.lastOrganizedDate {
                HStack(spacing: 4) {
                    Text("Last organized:")
                    Text(date, style: .date)
                    Text(date, style: .time)
                }.font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("picoLastContextOrganization")
            }
            Toggle("Use recent app name as context", isOn: $coordinator.appContextEnabled)
                .accessibilityIdentifier("picoAppContextEnabled")
            Text("Only the app name is read, for up to 15 minutes. No screen content, window titles or typed text.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Toggle("System notifications", isOn: Binding(get: { coordinator.systemNotifications }, set: coordinator.setSystemNotifications))
                .accessibilityIdentifier("picoProactiveNotifications")
            if let message = coordinator.settingsMessage { Text(message).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
    }
}
