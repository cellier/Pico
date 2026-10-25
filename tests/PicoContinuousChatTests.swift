import Foundation

/// Exercises the real native inbox and worker pipe with deterministic protocol
/// events. This fixture uses no agent runtime, provider, UI or user data.
@main struct PicoContinuousChatTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicoContinuousChat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = ProcessInfo.processInfo.environment
        unsetenv("TELOS_PREVIEW"); unsetenv("PICO_FILES_DIR")
        defer {
            try? FileManager.default.removeItem(at: root)
            for key in ["TELOS_PREVIEW", "PICO_FILES_DIR"] {
                if let value = original[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        try await testBurstReplies(root.appendingPathComponent("burst"))
        try await testFinalExitGap(root.appendingPathComponent("final-gap"))
        try await testSaveFailure(root.appendingPathComponent("save-failure"))
        try await testStopAndRestart(root.appendingPathComponent("restart"))
        try await testVoiceReplyOwnership(root.appendingPathComponent("voice"))
        try await testUnansweredVoiceTerminal(root.appendingPathComponent("unanswered-voice"))
        try await testIndependentFailureRetry(root.appendingPathComponent("independent-retries"))
        try testCheckpointVoiceOwnership(root.appendingPathComponent("checkpoint-voice"))
        try await testArtifactReplyOwnership(root.appendingPathComponent("artifact-ownership"))
        try await testReplyCoverage(root.appendingPathComponent("coverage"))
        try await testPendingVoiceAdmission(root.appendingPathComponent("voice-admission"))
        try await testScopedVoiceCancellation(root.appendingPathComponent("scoped-voice-cancel"))
        print("PASS: continuous Chat accepts and saves bursts; merged/independent replies and terminal deduplication; final/exit queue handoff; failed-save draft safety; stop/restart retention; exact voice reply ownership")
    }

    @MainActor private static func make(_ root: URL) throws -> PicoChatStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = root.appendingPathComponent("continuous-fixture.py")
        try Data(workerSource.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: script.path)
        let python = [ProcessInfo.processInfo.environment["PICO_TEST_PYTHON"],
                      FileManager.default.currentDirectoryPath + "/.runtime/venv/bin/python", "/usr/bin/python3"].compactMap { $0 }
            .first { FileManager.default.isExecutableFile(atPath: $0) }!
        let store = PicoChatStore(dataDir: root)
        store.workerFixtureForTesting = (python: python, script: script)
        return store
    }

    @MainActor private static func wait(_ label: String, timeout: TimeInterval = 8, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Continuous Chat timed out: " + label)
    }

    private static func snapshot(_ root: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("chat.json"))) as! [String: Any]
    }

    private static func ids(_ value: [String: Any], _ key: String) -> Set<UUID> {
        Set((value[key] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
    }

    private static func records(_ root: URL, name: String = "fixture-requests.jsonl") throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    @MainActor private static func testBurstReplies(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        precondition(chat.send("burst A: draft the introduction"))
        await wait("first burst worker") { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        let first = chat.messages.first { $0.role == "user" }!.id
        precondition(chat.send("burst B: keep that introduction brief"), "A supplement must be accepted while the first turn is running")
        precondition(chat.send("burst C: a separate question"), "An independent message must be accepted without waiting for the first reply")
        let users = chat.messages.filter { $0.role == "user" }
        precondition(users.map(\.text) == ["burst A: draft the introduction", "burst B: keep that introduction brief", "burst C: a separate question"])
        precondition(users.count == 3 && Set(users.map(\.id)).count == 3 && users[0].id == first)
        let accepted = try snapshot(root)
        let persistedUsers = (accepted["messages"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "user" }
        precondition(persistedUsers.compactMap { UUID(uuidString: $0["id"] as? String ?? "") } == users.map(\.id),
                     "Every accepted message must be durably saved before send returns, including while replying")
        precondition(Set(users.map(\.id)).isSubset(of: ids(accepted, "pendingMessageIDs")),
                     "Accepted messages must remain pending until a reply explicitly handles them")
        await wait("merged and independent burst replies") { !chat.isRunning && chat.messages.filter { $0.role == "assistant" }.count == 2 }
        let replies = chat.messages.filter { $0.role == "assistant" }
        precondition(replies.map(\.text) == ["One brief introduction incorporating A and B.", "The separate answer for C."])
        precondition(chat.messages.count == 5 && Set(replies.map(\.id)).count == 2,
                     "Duplicate reply events and done events must not append another assistant bubble")
        let completed = try snapshot(root)
        precondition(ids(completed, "pendingMessageIDs").isEmpty && ids(completed, "inFlightMessageIDs").isEmpty)
        let received = try records(root, name: "fixture-inputs.jsonl")
        let delivered = received.flatMap { $0["messages"] as? [[String: Any]] ?? [] }
        precondition(Set(delivered.compactMap { UUID(uuidString: $0["id"] as? String ?? "") }) == Set(users.dropFirst().map(\.id)))
        precondition(received.allSatisfy { $0["type"] as? String == "chat_message" && UUID(uuidString: $0["run_id"] as? String ?? "") != nil })
        let reopened = try make(root)
        defer { reopened.stop() }
        precondition(reopened.messages.map(\.id) == chat.messages.map(\.id), "A reload must retain stable reply IDs and every original user bubble")
    }

    @MainActor private static func testFinalExitGap(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        precondition(chat.send("linger-final A"))
        await wait("final event while worker still lives") {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-final-sent").path) &&
            chat.status == "idle" && chat.messages.contains { $0.role == "assistant" && $0.text == "First final reply." }
        }
        precondition(chat.send("next run B"), "A new message in the done-to-exit gap must be accepted and queued")
        let userIDs = chat.messages.filter { $0.role == "user" }.map(\.id)
        precondition(userIDs.count == 2)
        let saved = try snapshot(root)
        precondition(ids(saved, "pendingMessageIDs").contains(userIDs[1]))
        await wait("next run after first process exits") { !chat.isRunning && chat.messages.filter { $0.role == "assistant" }.count == 2 }
        let requests = try records(root)
        precondition(requests.count == 2, "The second message must start one new run after the completed process exits")
        let second = requests[1]["messages"] as? [[String: Any]] ?? []
        precondition(second.compactMap { UUID(uuidString: $0["id"] as? String ?? "") } == [userIDs[1]])
        precondition(chat.messages.filter { $0.role == "assistant" }.map(\.text) == ["First final reply.", "Reply: next run B"])
        precondition(chat.messages.filter { $0.role == "user" }.map(\.id) == userIDs)
    }

    @MainActor private static func testSaveFailure(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        precondition(chat.send("hold current A"))
        await wait("busy worker before disk failure") { chat.status == "working" }
        let existingUsers = chat.messages.filter { $0.role == "user" }.map(\.id)
        let existingResponse = chat.responseMessageID
        let file = root.appendingPathComponent("draft-attachment.txt")
        try Data("Unsent local attachment".utf8).write(to: file)
        chat.draft = "Keep this message after save failure"
        chat.files = [ComposerFile(name: file.lastPathComponent, path: file.path)]
        try FileManager.default.removeItem(at: root.appendingPathComponent("chat.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chat.json"), withIntermediateDirectories: false)
        precondition(!chat.send(), "A message must not report acceptance before its durable write succeeds")
        precondition(chat.draft == "Keep this message after save failure" && chat.files.map(\.path) == [file.path])
        precondition(chat.messages.filter { $0.role == "user" }.map(\.id) == existingUsers,
                     "A failed send must roll back its bubble and queue membership, preserving the active user message")
        precondition(chat.isRunning && chat.responseMessageID == existingResponse,
                     "Failure to save a new message must not discard the existing worker or response owner")
        let requests = try records(root)
        precondition(requests.count == 1)
    }

    @MainActor private static func testStopAndRestart(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        precondition(chat.send("hold current A"))
        await wait("current worker before queued stop") { chat.status == "working" }
        precondition(chat.send("pending B survives interruption"))
        let originalUsers = chat.messages.filter { $0.role == "user" }.map(\.id)
        let runningSnapshot = try Data(contentsOf: root.appendingPathComponent("chat.json"))
        let running = try snapshot(root)
        precondition(originalUsers.count == 2 && ids(running, "pendingMessageIDs").isSuperset(of: originalUsers))
        chat.stop()
        let stopped = try snapshot(root)
        let retained = ids(stopped, "pendingMessageIDs").union(ids(stopped, "retryMessageIDs")).union(ids(stopped, "inFlightMessageIDs"))
        precondition(retained.isSuperset(of: originalUsers),
                     "Stopping the current run must retain every unanswered accepted message as pending or explicit retry")

        // Reopen a copied running snapshot in another private directory. The old
        // store may drain genuinely unsent work after stop; it must not race the
        // simulated crashed app's recovery or overwrite its private snapshot.
        let recovery = root.appendingPathComponent("recovered")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try runningSnapshot.write(to: recovery.appendingPathComponent("chat.json"), options: .atomic)
        try FileManager.default.copyItem(at: root.appendingPathComponent("fixture-requests.jsonl"),
                                         to: recovery.appendingPathComponent("fixture-requests.jsonl"))
        let restarted = try make(recovery)
        defer { restarted.stop() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await wait("recovered inbox settles") { !restarted.isRunning }
        let recovered = try snapshot(recovery)
        let wasDelivered = ids(running, "inFlightMessageIDs")
        precondition(wasDelivered.isSubset(of: ids(recovered, "retryMessageIDs")),
                     "Delivered work may already have acted and must require explicit retry after a crash")
        precondition(restarted.messages.filter { $0.role == "user" }.map(\.id) == originalUsers)
        let requests = try records(recovery)
        let replayedIDs = requests.dropFirst().flatMap { $0["messages"] as? [[String: Any]] ?? [] }
            .compactMap { UUID(uuidString: $0["id"] as? String ?? "") }
        precondition(Set(replayedIDs).isDisjoint(with: wasDelivered),
                     "Recovery must never automatically replay an accepted run with uncertain external actions")
        let unanswered = ids(recovered, "pendingMessageIDs").union(ids(recovered, "retryMessageIDs")).union(ids(recovered, "inFlightMessageIDs"))
        let safelyUnsent = Set(originalUsers).subtracting(wasDelivered)
        if restarted.messages.filter({ $0.role == "assistant" }).isEmpty {
            precondition(safelyUnsent.isSubset(of: unanswered), "Unsent messages must remain available after restart")
        }
    }

    @MainActor private static func testVoiceReplyOwnership(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        let voiceID = UUID().uuidString
        precondition(chat.sendVoice("voice owner V", requestID: voiceID, language: "zh"))
        await wait("voice worker before typed follow-up") { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        precondition(chat.send("typed independent C"))
        await wait("voice and independent typed replies") { !chat.isRunning && chat.voiceTurn(for: voiceID)?.state == "completed" }
        let turn = chat.voiceTurn(for: voiceID)!
        let voiceReply = chat.messages.first { $0.id == turn.responseMessageID }
        precondition(turn.text == "只回答这条语音。" && voiceReply?.text == turn.text && turn.language == "zh")
        precondition(chat.messages.filter { $0.role == "assistant" }.map(\.text) == ["Independent typed result.", "只回答这条语音。"])
        precondition(chat.messages.count == 4 && turn.userMessageID == UUID(uuidString: voiceID),
                     "The voice result must be selected by reply_to, never the latest unrelated Chat answer or done.text")
        let requests = try records(root)
        precondition(requests.count == 1 && requests[0]["voice_request_id"] as? String == voiceID)
        precondition(chat.sendVoice("duplicate must not run", requestID: voiceID, language: "en"))
        precondition(chat.messages.count == 4, "Replaying the original voice request must retain its exact answer mapping")
    }

    @MainActor private static func testUnansweredVoiceTerminal(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        let id = UUID().uuidString
        precondition(chat.sendVoice("voice unanswered V", requestID: id, language: "zh"))
        await wait("unanswered voice worker") { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        precondition(chat.send("typed C answered while voice is unresolved"))
        await wait("partial handled batch ends") { !chat.isRunning }
        let voice = chat.voiceTurn(for: id)!
        precondition(["error", "needs_input", "cancelled"].contains(voice.state),
                     "A consumed but unanswered voice message must leave the pet in an explicit terminal state")
        precondition(voice.responseMessageID == nil && !voice.text.isEmpty && voice.text != "Typed C only.",
                     "The unresolved voice must never borrow an independent typed answer as its spoken result")
        precondition(chat.messages.filter { $0.role == "assistant" }.map(\.text) == ["Typed C only."])
        let saved = try snapshot(root)
        precondition(saved["activeVoiceRequestID"] == nil && ids(saved, "retryMessageIDs").contains(UUID(uuidString: id)!))
        let reopened = try make(root)
        defer { reopened.stop() }
        precondition(reopened.voiceTurn(for: id)?.state == voice.state && reopened.voiceTurn(for: id)?.responseMessageID == nil,
                     "The unresolved voice terminal state must persist for companion restart recovery")
    }

    @MainActor private static func testIndependentFailureRetry(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        precondition(chat.send("failure A"))
        await wait("first independent failure") { !chat.isRunning }
        let first = chat.messages.first { $0.role == "user" }!.id
        precondition(chat.send("failure B"))
        await wait("second independent failure") { !chat.isRunning }
        let users = chat.messages.filter { $0.role == "user" }.map(\.id)
        let second = users[1]
        let failed = try snapshot(root)
        precondition(ids(failed, "retryMessageIDs") == Set([first, second]),
                     "An independent failure must not overwrite an older unanswered retry request")
        precondition(ids(failed, "lastRetryMessageIDs") == Set([second]),
                     "The retry button must identify the most recent failed group, not all old failed requests")
        chat.retry()
        await wait("retry most recent group") { !chat.isRunning }
        let requests = try records(root)
        precondition(requests.count == 3)
        let retried = requests[2]["messages"] as? [[String: Any]] ?? []
        precondition(retried.compactMap { UUID(uuidString: $0["id"] as? String ?? "") } == [second],
                     "Retrying B must not unexpectedly redo A's earlier, potentially external work")
        precondition(chat.messages.filter { $0.role == "user" }.map(\.id) == users)
        precondition(chat.messages.filter { $0.role == "assistant" }.map(\.text) == ["Recovered B only."])
        let completed = try snapshot(root)
        precondition(ids(completed, "retryMessageIDs") == Set([first]),
                     "Completing B removes only B from the retry ledger and preserves A")
        let reopened = try make(root)
        defer { reopened.stop() }
        let afterReload = try snapshot(root)
        precondition(ids(afterReload, "retryMessageIDs") == Set([first]) && reopened.messages.map(\.id) == chat.messages.map(\.id))
    }

    @MainActor private static func testCheckpointVoiceOwnership(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversation = UUID(), voice = UUID(), typed = UUID(), run = UUID()
        let messages = [Message(id: voice, role: "user", text: "Unanswered spoken request", date: Date(), origin: "voice"),
                        Message(id: typed, role: "user", text: "An independent typed question", date: Date())]
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages))
        let saved: [String: Any] = ["conversationID": conversation.uuidString, "messages": encoded, "artifacts": [], "status": "working",
                                     "activeRunID": run.uuidString, "activeVoiceRequestID": voice.uuidString,
                                     "pendingMessageIDs": [voice.uuidString, typed.uuidString], "inFlightMessageIDs": [voice.uuidString, typed.uuidString],
                                     "voiceTurns": [voice.uuidString: ["requestID": voice.uuidString, "userMessageID": voice.uuidString,
                                                                       "language": "zh", "state": "working", "text": ""]]]
        try JSONSerialization.data(withJSONObject: saved).write(to: root.appendingPathComponent("chat.json"))
        let directory = root.appendingPathComponent("chats/" + conversation.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let checkpoint: [String: Any] = ["run_id": run.uuidString,
                                          "event": ["type": "done", "run_id": run.uuidString, "status": "ready", "text": "Typed answer only.",
                                                    "reply_to": [typed.uuidString], "handled_message_ids": [typed.uuidString],
                                                    "consumed_message_ids": [voice.uuidString, typed.uuidString]]]
        try JSONSerialization.data(withJSONObject: checkpoint).write(to: directory.appendingPathComponent("last-turn.json"))
        let chat = try make(root)
        defer { chat.stop() }
        let turn = chat.voiceTurn(for: voice.uuidString)!
        precondition(["needs_input", "error", "cancelled"].contains(turn.state) && turn.responseMessageID == nil,
                     "Checkpoint recovery must not map an unrelated typed final answer to an unanswered voice request")
        precondition(turn.text != "Typed answer only." && !turn.text.isEmpty)
        let reply = chat.messages.first { $0.role == "assistant" }!
        precondition(chat.messages.count == 3 && reply.text == "Typed answer only." && reply.replyTo == [typed])
        let recovered = try snapshot(root)
        precondition(ids(recovered, "retryMessageIDs") == Set([voice]) && ids(recovered, "pendingMessageIDs").isEmpty)
        let launched = try records(root)
        precondition(launched.isEmpty, "Recovering checkpoint results must not relaunch either request")
        let reopened = try make(root)
        defer { reopened.stop() }
        precondition(reopened.messages.map(\.id) == chat.messages.map(\.id) && reopened.voiceTurn(for: voice.uuidString)?.responseMessageID == nil)
    }

    @MainActor private static func testArtifactReplyOwnership(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        precondition(chat.send("artifact A: make report.pdf"))
        await wait("artifact worker") { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        precondition(chat.send("artifact C: answer an independent question"))
        await wait("artifact addressed replies") { !chat.isRunning && chat.messages.filter { $0.role == "assistant" }.count == 2 }
        let replies = chat.messages.filter { $0.role == "assistant" }
        precondition(replies[0].text == "An independent answer without a file." && (replies[0].artifacts ?? []).isEmpty,
                     "The first unrelated reply must not take another request's pending artifact")
        precondition(replies[1].text == "Your report is ready: report.pdf." && replies[1].artifacts?.map(\.name) == ["report.pdf"])
        precondition(chat.artifacts.count == 1 && chat.pendingArtifacts.isEmpty && chat.unassignedArtifacts.isEmpty)
        let reopened = try make(root)
        defer { reopened.stop() }
        let savedReplies = reopened.messages.filter { $0.role == "assistant" }
        precondition(savedReplies.map(\.id) == replies.map(\.id) && (savedReplies[0].artifacts ?? []).isEmpty && savedReplies[1].artifacts?.count == 1,
                     "Reloading must preserve the file on its addressed reply, without moving or duplicating it")
    }

    @MainActor private static func testReplyCoverage(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        let voice = UUID().uuidString
        precondition(chat.sendVoice("coverage A: original spoken request", requestID: voice, language: "zh"))
        await wait("coverage worker") { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        precondition(chat.send("coverage B: amend that original request"))
        await wait("first reply before coverage reconciliation") {
            FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-before-coverage").path) &&
            chat.messages.filter { $0.role == "assistant" }.count == 1
        }
        let users = chat.messages.filter { $0.role == "user" }.map(\.id)
        let originalReply = chat.messages.first { $0.role == "assistant" }!
        precondition(originalReply.replyTo == [users[1]])
        let beforeCoverage = try Data(contentsOf: root.appendingPathComponent("chat.json"))
        let running = try snapshot(root)
        try Data().write(to: root.appendingPathComponent("fixture-release-coverage"))
        await wait("same reply receives corrected coverage") { !chat.isRunning && chat.voiceTurn(for: voice)?.state == "completed" }
        let replies = chat.messages.filter { $0.role == "assistant" }
        precondition(chat.messages.count == 3 && replies.count == 1 && replies[0].id == originalReply.id && replies[0].text == originalReply.text,
                     "Coverage reconciliation must update one existing bubble, never resend its visible text")
        precondition(Set(replies[0].replyTo ?? []) == Set(users))
        precondition(chat.voiceTurn(for: voice)?.responseMessageID == originalReply.id && chat.voiceTurn(for: voice)?.text == originalReply.text,
                     "An explicitly covered voice request must map to the same existing reply")
        let completed = try snapshot(root)
        precondition(ids(completed, "pendingMessageIDs").isEmpty && ids(completed, "retryMessageIDs").isEmpty)

        // The journal has the expanded coverage, but the native crash snapshot
        // still has only the first reply. Recovery must union onto its stable ID.
        let recovery = root.appendingPathComponent("recovered")
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try beforeCoverage.write(to: recovery.appendingPathComponent("chat.json"))
        let conversation = (running["conversationID"] as! String).lowercased()
        let run = (running["activeRunID"] as! String).lowercased()
        let relative = "chats/" + conversation + "/reply-journal/" + run + ".json"
        let target = recovery.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(relative), to: target)
        let recovered = try make(recovery)
        defer { recovered.stop() }
        let recoveredReplies = recovered.messages.filter { $0.role == "assistant" }
        precondition(recovered.messages.count == 3 && recoveredReplies.count == 1 && recoveredReplies[0].id == originalReply.id)
        precondition(Set(recoveredReplies[0].replyTo ?? []) == Set(users) && recoveredReplies[0].text == originalReply.text)
        precondition(recovered.voiceTurn(for: voice)?.responseMessageID == originalReply.id && recovered.voiceTurn(for: voice)?.state == "completed")
        let recoveredState = try snapshot(recovery)
        let relaunched = try records(recovery)
        precondition(ids(recoveredState, "pendingMessageIDs").isEmpty && ids(recoveredState, "retryMessageIDs").isEmpty && relaunched.isEmpty,
                     "Journal recovery must not replay already resolved work or append the same response again")
    }

    @MainActor private static func testPendingVoiceAdmission(_ root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversation = UUID(), pending = Message(role: "user", text: "Saved pending typed B", date: Date())
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode([pending]))
        let saved: [String: Any] = ["conversationID": conversation.uuidString, "messages": encoded, "artifacts": [], "status": "idle",
                                     "pendingMessageIDs": [pending.id.uuidString]]
        try JSONSerialization.data(withJSONObject: saved).write(to: root.appendingPathComponent("chat.json"))
        let chat = try make(root)
        defer { chat.stop() }
        let voice = UUID().uuidString
        precondition(!chat.canBeginVoiceTurn && !chat.sendVoice("Do not mix with older pending typed work", requestID: voice, language: "en"),
                     "A voice turn must wait while older native messages are queued for dispatch")
        precondition(chat.voiceTurn(for: voice) == nil && chat.messages.count == 1)
        await wait("older pending typed request finishes") { !chat.isRunning && chat.messages.filter { $0.role == "assistant" }.count == 1 }
        precondition(chat.canBeginVoiceTurn && chat.voiceTurn(for: voice) == nil)
        let requests = try records(root)
        precondition(requests.count == 1 && requests[0]["voice"] as? Bool != true)
    }

    @MainActor private static func testScopedVoiceCancellation(_ root: URL) async throws {
        let chat = try make(root)
        defer { chat.stop() }
        let voice = UUID().uuidString
        precondition(chat.sendVoice("voice cancel V", requestID: voice, language: "zh"))
        await wait("voice before independent typed request") { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        precondition(chat.send("typed B must continue after voice cancellation"))
        await wait("both inputs delivered to the same worker") { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-multi-voice-ready").path) }
        let users = chat.messages.filter { $0.role == "user" }.map(\.id)
        precondition(users.count == 2 && users[0] == UUID(uuidString: voice))
        chat.stopVoice(requestID: voice)
        precondition(chat.voiceTurn(for: voice)?.state == "cancelled" && chat.voiceTurn(for: voice)?.responseMessageID == nil,
                     "Cancelling one spoken input must immediately finish that exact pet request without borrowing a reply")
        precondition(chat.isRunning, "A pet cancellation must not terminate the worker that also owns an independent typed request")
        await wait("independent typed answer after scoped cancellation") { !chat.isRunning }
        precondition(chat.messages.filter { $0.role == "user" }.map(\.id) == users,
                     "A cancellation control must not synthesize another user message")
        let replies = chat.messages.filter { $0.role == "assistant" }
        precondition(chat.messages.count == 3 && replies.count == 1 && replies[0].text == "Typed B completed after voice cancellation." && replies[0].replyTo == [users[1]])
        precondition(chat.voiceTurn(for: voice)?.state == "cancelled" && chat.voiceTurn(for: voice)?.responseMessageID == nil,
                     "The cancelled voice request must not later receive the independent typed answer or become completed")
        let controls = try records(root, name: "fixture-inputs.jsonl")
        let cancel = controls.filter { $0["type"] as? String == "chat_cancel" }
        precondition(cancel.count == 1 && Set((cancel[0]["message_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))) == Set([users[0]]))
        let requests = try records(root)
        precondition(requests.count == 1, "Scoped cancellation must let the existing worker finish B instead of restarting either input")
    }

    private static let workerSource = #"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

root = Path(os.environ["TELOS_DATA_DIR"])
initial = json.loads(sys.stdin.readline())
run_id = initial["run_id"]
def record(name, value):
    with (root / name).open("a", encoding="utf-8") as output:
        output.write(json.dumps(value, ensure_ascii=False) + "\n")
        output.flush()
def emit(kind, **values):
    print(json.dumps(dict(type=kind, run_id=run_id, **values), ensure_ascii=False), flush=True)
def canonical(value):
    return str(uuid.UUID(value)).upper()
messages = initial.get("messages") or [{"id": initial["message_id"], "text": initial["prompt"]}]
by_id = {canonical(m["id"]): m for m in messages}
record("fixture-requests.jsonl", initial)
prompt = initial["prompt"]
emit("phase", status="working")
def receive_until(count):
    while len(by_id) < count:
        line = sys.stdin.readline()
        if not line:
            raise RuntimeError("The native input closed before all accepted messages arrived")
        value = json.loads(line)
        record("fixture-inputs.jsonl", value)
        assert value["type"] == "chat_message" and value["run_id"] == run_id
        for message in value["messages"]:
            by_id[canonical(message["id"])] = message
    return list(by_id)
def reply(label, text, owners):
    value = dict(message_id=str(uuid.uuid5(uuid.NAMESPACE_URL, run_id + "/" + label)).upper(), text=text, reply_to=owners)
    emit("chat_reply", **value)
    return value
if prompt.startswith("burst A"):
    owners = receive_until(3)
    emit("chat_messages_consumed", message_ids=owners)
    combined = reply("ab", "One brief introduction incorporating A and B.", owners[:2])
    reply("c", "The separate answer for C.", owners[2:])
    emit("chat_reply", **combined)
    emit("done", text="", status="ready", handled_message_ids=owners, consumed_message_ids=owners)
    emit("done", text="duplicate terminal must not create a bubble", status="ready", handled_message_ids=owners, consumed_message_ids=owners)
elif prompt.startswith("linger-final"):
    owners = list(by_id)
    emit("chat_messages_consumed", message_ids=owners)
    reply("first", "First final reply.", owners)
    emit("done", text="", status="ready", handled_message_ids=owners, consumed_message_ids=owners)
    (root / "fixture-final-sent").write_text("done", encoding="utf-8")
    time.sleep(0.7)
elif prompt.startswith("hold current"):
    emit("chat_messages_consumed", message_ids=list(by_id))
    time.sleep(20)
elif prompt.startswith("voice owner"):
    owners = receive_until(2)
    emit("chat_messages_consumed", message_ids=owners)
    reply("typed", "Independent typed result.", owners[1:])
    reply("voice", "只回答这条语音。", owners[:1])
    emit("done", text="WRONG blanket terminal text", status="ready", handled_message_ids=owners, consumed_message_ids=owners)
elif prompt.startswith("voice unanswered"):
    owners = receive_until(2)
    emit("chat_messages_consumed", message_ids=owners)
    reply("typed-only", "Typed C only.", owners[1:])
    emit("done", text="", status="ready", handled_message_ids=owners[1:], consumed_message_ids=owners)
elif prompt.startswith("voice cancel"):
    owners = receive_until(2)
    emit("chat_messages_consumed", message_ids=owners)
    (root / "fixture-multi-voice-ready").write_text("both inputs", encoding="utf-8")
    cancel = json.loads(sys.stdin.readline())
    record("fixture-inputs.jsonl", cancel)
    assert cancel["type"] == "chat_cancel" and cancel["run_id"] == run_id
    assert [canonical(key) for key in cancel["message_ids"]] == owners[:1]
    reply("typed-after-cancel", "Typed B completed after voice cancellation.", owners[1:])
    emit("done", text="", status="ready", reply_to=[], handled_message_ids=owners, consumed_message_ids=owners)
elif prompt.startswith("artifact A"):
    owners = receive_until(2)
    emit("chat_messages_consumed", message_ids=owners)
    output = root / "report.pdf"
    output.write_text("Private fixture artifact metadata only.", encoding="utf-8")
    emit("artifact", path=str(output), name="report.pdf")
    reply("independent", "An independent answer without a file.", owners[1:])
    reply("report", "Your report is ready: report.pdf.", owners[:1])
    emit("done", text="", status="ready", handled_message_ids=owners, consumed_message_ids=owners)
elif prompt.startswith("coverage A"):
    owners = receive_until(2)
    emit("chat_messages_consumed", message_ids=owners)
    visible = reply("combined", "One combined answer for A and B.", owners[1:])
    (root / "fixture-before-coverage").write_text("first reply", encoding="utf-8")
    deadline = time.monotonic() + 8
    while not (root / "fixture-release-coverage").exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    visible["reply_to"] = owners
    folder = root / "chats" / canonical(initial["task_id"]).lower() / "reply-journal"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / (canonical(run_id).lower() + ".json")).write_text(json.dumps({"run_id": run_id, "replies": [visible]}), encoding="utf-8")
    emit("chat_reply_coverage", message_id=visible["message_id"], reply_to=owners)
    emit("chat_reply_coverage", message_id=visible["message_id"], reply_to=owners)
    emit("done", text="", status="ready", reply_to=[], handled_message_ids=owners, consumed_message_ids=owners, delivered_replies=[visible])
elif prompt in ("failure A", "failure B"):
    owners = list(by_id)
    emit("chat_messages_consumed", message_ids=owners)
    attempts = [json.loads(line) for line in (root / "fixture-requests.jsonl").read_text(encoding="utf-8").splitlines()]
    if prompt == "failure B" and sum(value["prompt"] == prompt for value in attempts) > 1:
        reply("retried-b", "Recovered B only.", owners)
        emit("done", text="", status="ready", handled_message_ids=owners, consumed_message_ids=owners)
    else:
        emit("error", text="Deliberate isolated " + prompt)
else:
    owners = list(by_id)
    emit("chat_messages_consumed", message_ids=owners)
    reply("normal", "Reply: " + prompt, owners)
    emit("done", text="", status="ready", handled_message_ids=owners, consumed_message_ids=owners)
"""#
}
