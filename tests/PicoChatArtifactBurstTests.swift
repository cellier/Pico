import Combine
import Foundation

/// Actual PicoChatStore + native pipes + a private no-model producer. A burst
/// must publish batches, retain its response owner, and flush before terminals.
@main struct PicoChatArtifactBurstTests {
    @MainActor static func main() throws {
        precondition(Bundle.main.object(forInfoDictionaryKey: "PicoArtifactBurstFixture") as? Bool == true,
                     "Run only in the isolated no-model fixture bundle")
        let original = ProcessInfo.processInfo.environment
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pico-artifact-burst-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("TELOS_DATA_DIR", root.path, 1); unsetenv("TELOS_PREVIEW"); unsetenv("PICO_FILES_DIR")
        defer {
            try? FileManager.default.removeItem(at: root)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW", "PICO_FILES_DIR"] {
                if let value = original[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let chat = PicoChatStore(dataDir: root)
        let count = 3763
        var pendingPublications = 0, indexPublications = 0
        var subscriptions = Set<AnyCancellable>()
        chat.$pendingArtifacts.dropFirst().sink { _ in pendingPublications += 1 }.store(in: &subscriptions)
        chat.$artifacts.dropFirst().sink { _ in indexPublications += 1 }.store(in: &subscriptions)
        var completed: [UUID: [String: String]] = [:]
        var totalUniqueFiles = 0
        func wait(_ label: String, timeout: TimeInterval = 25, _ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(timeout)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            precondition(predicate(), "Native artifact lifecycle timed out: \(label)")
        }
        func artifacts(_ files: [Artifact]?, owner: UUID) -> [String: String] {
            let files = files ?? []
            precondition(files.count == count && Set(files.map(\.path)).count == count,
                         "A burst must retain every unique path exactly once")
            let expected = owner.uuidString.lowercased()
            precondition(files.allSatisfy { URL(fileURLWithPath: $0.path).deletingLastPathComponent().lastPathComponent == expected },
                         "A delayed batch must never cross response/run ownership")
            let result = Dictionary(uniqueKeysWithValues: files.map { ($0.path, $0.name) })
            for index in [0, count / 2, count - 1] {
                let matching = files.first { URL(fileURLWithPath: $0.path).lastPathComponent == "\(index).dat" }
                precondition(matching?.name == "updated-artifact-\(index).dat", "Repeated path must keep the latest metadata")
            }
            return result
        }
        func snapshotReply(_ owner: UUID) throws -> [String: String] {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("chat.json"))) as! [String: Any]
            let messages = json["messages"] as! [[String: Any]]
            let match = messages.filter { ($0["id"] as? String)?.lowercased() == owner.uuidString.lowercased() }
            precondition(match.count == 1 && match[0]["role"] as? String == "assistant")
            let files = match[0]["artifacts"] as? [[String: Any]] ?? []
            precondition(files.count == count && (json["pendingArtifacts"] as? [Any] ?? []).isEmpty)
            return Dictionary(uniqueKeysWithValues: files.map { ($0["path"] as! String, $0["name"] as! String) })
        }
        func verifyCommitted(_ owner: UUID, mode: String) throws {
            guard let message = chat.messages.first(where: { $0.id == owner }) else { preconditionFailure("Live response identity disappeared") }
            precondition(message.role == "assistant" && chat.responseMessageID == nil && chat.pendingArtifacts.isEmpty)
            let expected = artifacts(message.artifacts, owner: owner)
            let saved = try snapshotReply(owner)
            precondition(saved == expected, "Terminal handling must flush the entire burst before saving")
            totalUniqueFiles += count
            precondition(chat.artifacts.count == totalUniqueFiles && Set(chat.artifacts.map(\.path)).count == totalUniqueFiles)
            precondition(chat.unassignedArtifacts.isEmpty, "All burst files must stay attached to their response")
            completed[owner] = expected
            precondition(pendingPublications < 100 && indexPublications < 100,
                         "A3763-file burst must publish batches instead of notifying observers for every file: pending=\(pendingPublications), index=\(indexPublications)")
            let reloaded = PicoChatStore(dataDir: root)
            for (id, files) in completed {
                let reply = reloaded.messages.first { $0.id == id }
                precondition(reply?.artifacts?.count == count)
                let recovered = Dictionary(uniqueKeysWithValues: (reply!.artifacts ?? []).map { ($0.path, $0.name) })
                precondition(recovered == files, "Reopening must retain every previous turn's exact files")
            }
            print("PASS \(mode):\(count) paths/latest duplicate metadata, stable response owner, durable reload; pending publishes=\(pendingPublications), index publishes=\(indexPublications)")
        }
        for mode in ["burst done", "burst error", "burst abrupt"] {
            pendingPublications = 0; indexPublications = 0
            precondition(chat.send(mode))
            let owner = chat.responseMessageID!
            wait(mode) { !chat.isRunning }
            precondition(chat.status == (mode == "burst done" ? "idle" : "error"))
            if mode == "burst done" { precondition(chat.messages.last?.text == "Final burst result") }
            if mode == "burst error" { precondition(chat.error == "Deliberate burst error") }
            try verifyCommitted(owner, mode: mode)
        }

        pendingPublications = 0; indexPublications = 0
        precondition(chat.send("burst stop"))
        let stoppedOwner = chat.responseMessageID!
        wait("stop boundary") { chat.status == "burst-ready-to-stop" }
        chat.stop()
        precondition(!chat.isRunning && chat.status == "paused")
        try verifyCommitted(stoppedOwner, mode: "stop synchronous flush")
        let users = chat.messages.filter { $0.role == "user" }.count
        pendingPublications = 0; indexPublications = 0
        chat.retry()
        let retryOwner = chat.responseMessageID!
        precondition(retryOwner != stoppedOwner)
        wait("retry boundary") { chat.status == "burst-ready-to-stop" }
        wait("running burst persisted") { chat.pendingArtifacts.count == count }
        _ = artifacts(chat.pendingArtifacts, owner: retryOwner)

        // A copied in-flight snapshot models a crash without killing the app or
        // interfering with the producer whose stop path is tested below.
        let recovery = root.appendingPathComponent("recovery")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent("chat.json"), to: recovery.appendingPathComponent("chat.json"))
        let recovered = PicoChatStore(dataDir: recovery)
        precondition(recovered.status == "paused" && recovered.responseMessageID == nil && recovered.pendingArtifacts.isEmpty)
        let recoveredReply = recovered.messages.first { $0.id == retryOwner }
        _ = artifacts(recoveredReply?.artifacts, owner: retryOwner)
        precondition(recovered.unassignedArtifacts.isEmpty, "A crash must not detach buffered outputs from their live owner")
        chat.stop()
        precondition(chat.messages.filter { $0.role == "user" }.count == users, "Retry must not duplicate the user request")
        try verifyCommitted(retryOwner, mode: "stop/retry timer isolation and in-flight snapshot recovery")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(chat.pendingArtifacts.isEmpty && chat.messages.last?.id == retryOwner && chat.artifacts.count == totalUniqueFiles,
                     "A stale flush timer must not republish files after stop or alter a newer run")
        withExtendedLifetime(subscriptions) {}
        print("PASS actual native worker pipes and batching for18815 unique files across done/error/abrupt/stop/retry, immediate terminals, crash recovery, duplicate saves and run-scoped timers; no model, GUI or user-data access")
    }
}
