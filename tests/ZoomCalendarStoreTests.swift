import Foundation

private actor CalendarFixtureReader: ZoomCalendarReading {
    var current = ZoomCalendarBinding(enabled: true, connectionID: "connection-A")
    var cache: ZoomCalendarCache?
    var requests: [(Date, Date, String)] = []
    private var pending: [CheckedContinuation<ZoomCalendarResponse, Error>] = []
    func binding(directory: URL) -> ZoomCalendarBinding { current }
    func read(directory: URL, start: Date, end: Date, timeZone: String) async throws -> ZoomCalendarResponse {
        requests.append((start, end, timeZone))
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    func cached(directory: URL) -> ZoomCalendarCache? { cache }
    func save(_ value: ZoomCalendarCache?, directory: URL) { cache = value }
    func setBinding(_ value: ZoomCalendarBinding) { current = value }
    func setCache(_ value: ZoomCalendarCache) { cache = value }
    func count() -> Int { requests.count }
    func request(_ index: Int) -> (Date, Date, String) { requests[index] }
    func fail() {
        precondition(!pending.isEmpty)
        pending.removeFirst().resume(throwing: ZoomConnectionCommand.Failure.timedOut)
    }
    func respond(_ response: ZoomCalendarResponse) {
        precondition(!pending.isEmpty)
        pending.removeFirst().resume(returning: response)
    }
}

@main struct ZoomCalendarStoreTests {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-zoom-calendar-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func event(_ id: String, _ offset: Double = 0) -> ZoomCalendarEventValue {
            ZoomCalendarEventValue(id: id, title: "Synthetic " + id, start: Date().timeIntervalSince1970 + 3600 + offset,
                                   end: Date().timeIntervalSince1970 + 7200 + offset, allDay: false)
        }
        func response(_ events: [ZoomCalendarEventValue] = [], account: String? = "account-A", connection: String? = "connection-A",
                      state: String = "connected", complete: Bool = true) -> ZoomCalendarResponse {
            ZoomCalendarResponse(source: "zoom", state: state, message: complete ? "Synced" : "Synthetic sync unavailable",
                                 events: events, complete: complete, connection_id: connection, account_id: account)
        }
        func wait(_ condition: @MainActor () async -> Bool) async {
            for _ in 0..<300 {
                if await condition() { return }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            preconditionFailure("Isolated calendar fixture timed out")
        }
        let reader = CalendarFixtureReader()
        let cached = ZoomCalendarCache(connectionID: "connection-A", accountID: "account-A", timeZone: TimeZone.current.identifier,
                                       updated: Date(), events: [event("cached")])
        await reader.setCache(cached)
        let store = CalendarStore(directory: directory, reader: reader, automaticallyRefresh: false, previewMode: nil)
        store.refresh()
        await wait { await reader.count() == 1 }
        precondition(store.events.isEmpty && !store.authorized, "A cold cache is private until Zoom confirms its current account")
        for _ in 0..<12 { store.refresh(force: true) }
        let countBefore = await reader.count()
        precondition(countBefore == 1, "Refreshes must not start parallel Zoom processes")
        await reader.respond(response([event("first")]))
        await wait { await reader.count() == 2 }
        precondition(store.events.map(\.id) == ["first"])
        await reader.respond(response([event("changed", 1800), event("changed", 1800)]))
        await wait { !store.requesting }
        precondition(store.events.map(\.id) == ["changed"] && store.authorized && store.error == nil)
        store.refresh()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let throttled = await reader.count()
        precondition(throttled == 2, "Repeated window activation must not run another full sync")
        let request = await reader.request(0)
        let calendar = Calendar.current
        precondition(calendar.isDate(request.0, inSameDayAs: Date()) && calendar.component(.hour, from: request.0) == 0)
        precondition(request.1 == calendar.date(byAdding: .day, value: 7, to: request.0) && request.2 == TimeZone.current.identifier)

        store.refresh(force: true)
        await wait { await reader.count() == 3 }
        await reader.respond(response(state: "timeout", complete: false))
        await wait { !store.requesting }
        precondition(store.events.map(\.id) == ["changed"] && store.authorized && store.error != nil,
                     "A failed sync must preserve last-good results from the verified same account")
        store.refresh(force: true)
        await wait { await reader.count() == 4 }
        await reader.respond(response(account: "account-B", state: "timeout", complete: false))
        await wait { !store.requesting }
        precondition(store.events.isEmpty && !store.authorized, "Another account must never inherit old events, including failed reads")
        let cleared = await reader.cached(directory: directory)
        precondition(cleared == nil)
        store.refresh(force: true)
        await wait { await reader.count() == 5 }
        await reader.respond(response(account: "account-B"))
        await wait { !store.requesting }
        precondition(store.events.isEmpty && store.authorized && store.error == nil,
                     "Only a complete successful empty read is an empty calendar")

        store.refresh(force: true)
        await wait { await reader.count() == 6 }
        await reader.setBinding(ZoomCalendarBinding(enabled: true, connectionID: "connection-C"))
        store.connectionChanged()
        precondition(store.events.isEmpty && !store.authorized)
        await reader.respond(response([event("obsolete")], account: "account-B"))
        await wait { await reader.count() == 7 }
        precondition(!store.events.contains { $0.id == "obsolete" })
        await reader.respond(response([event("current-C")], account: "account-C", connection: "connection-C"))
        await wait { !store.requesting }
        precondition(store.events.map(\.id) == ["current-C"])
        store.refresh(force: true)
        await wait { await reader.count() == 8 }
        await reader.setBinding(ZoomCalendarBinding(enabled: false, connectionID: "connection-C"))
        store.connectionChanged()
        await reader.respond(response([event("after-disconnect")], account: "account-C", connection: "connection-C"))
        await wait { !store.requesting }
        precondition(store.events.isEmpty && !store.authorized && store.status == "disconnected")
        let afterDisconnect = await reader.cached(directory: directory)
        precondition(afterDisconnect == nil)

        let offlineReader = CalendarFixtureReader()
        await offlineReader.setCache(cached)
        let reopened = CalendarStore(directory: directory, reader: offlineReader, automaticallyRefresh: false, previewMode: nil)
        reopened.refresh()
        await wait { await offlineReader.count() == 1 }
        precondition(reopened.events.isEmpty)
        await offlineReader.respond(response(account: nil, state: "timeout", complete: false))
        await wait { !reopened.requesting }
        precondition(reopened.events.isEmpty && !reopened.authorized, "An unverified cold account must not expose cached data")
        reopened.refresh(force: true)
        await wait { await offlineReader.count() == 2 }
        await offlineReader.respond(response(state: "timeout", complete: false))
        await wait { !reopened.requesting }
        precondition(reopened.events.map(\.id) == ["cached"] && reopened.error != nil && reopened.authorized)
        reopened.refresh(force: true)
        await wait { await offlineReader.count() == 3 }
        await offlineReader.respond(response(account: nil, state: "timeout", complete: false))
        await wait { !reopened.requesting }
        precondition(reopened.events.map(\.id) == ["cached"], "An already verified unchanged connection keeps last-good events during an outage")
        reopened.refresh(force: true)
        await wait { await offlineReader.count() == 4 }
        await offlineReader.fail()
        await wait { !reopened.requesting }
        precondition(reopened.events.map(\.id) == ["cached"] && reopened.error != nil,
                     "A transport exception on the verified same connection preserves last-good events")
        reopened.refresh(force: true)
        await wait { await offlineReader.count() == 5 }
        await offlineReader.respond(response(account: nil, state: "needs_login", complete: false))
        await wait { !reopened.requesting }
        precondition(reopened.events.isEmpty && !reopened.authorized && reopened.needsSignIn,
                     "Explicit sign-in loss must immediately hide cached events")
        let signedOutCache = await offlineReader.cached(directory: directory)
        precondition(signedOutCache == nil)

        store.connectionChanged(state: "needs_login", message: "Sign in to Zoom to continue.")
        await wait { !store.requesting }
        precondition(store.needsSignIn && store.error == "Sign in to Zoom to continue.",
                     "A delayed connection notification must preserve the sign-in action")

        let disk = ZoomCalendarReader()
        await disk.save(cached, directory: directory)
        let saved = await disk.cached(directory: directory)
        precondition(saved?.accountID == "account-A" && saved?.events.first?.id == "cached")
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("zoom-events-cache.json").path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
        await disk.save(nil, directory: directory)
        let removed = await disk.cached(directory: directory)
        precondition(removed == nil)
        print("PASS Zoom calendar native sync: bounded single flight/coalescing, refresh throttling, seven-day scope, complete replacement and dedup, same-account last-good cache, external account change, stale response/disconnect rejection, identity-gated cold cache, private durable cache")
    }
}
