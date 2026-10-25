import Foundation

/// Real same-user file IPC and worker pipes, with private data and a stdlib-only
/// worker. No UI, microphone, model request, permissions scan or external send.
@main struct CompanionChatBridgeTests {
    @MainActor static func main() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("pico-voice-chat-" + UUID().uuidString)
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let original = ProcessInfo.processInfo.environment
        defer {
            try? files.removeItem(at: root)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW"] {
                if let value = original[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        try await testTranscriptAndReplay(root.appendingPathComponent("transcript"))
        try await testRecognitionAndLateCancellation(root.appendingPathComponent("recognition"))
        try await testTypedQueueAndDrafts(root.appendingPathComponent("typed-queue"))
        try await testPendingRestart(root.appendingPathComponent("restart"))
        try await testActiveVoiceRestart(root.appendingPathComponent("active-restart"), checkpoint: false)
        try await testActiveVoiceRestart(root.appendingPathComponent("checkpoint-restart"), checkpoint: true)
        try testTerminalQueueLeftovers(root.appendingPathComponent("terminal-queue"))
        try await testExplicitTaskTool(root.appendingPathComponent("task-tool"))
        print("PASS: companion voice uses durable Chat turns; replay/queued/active restart recovery; terminal queue leftovers never replay; ASR fallback and cancellation; typed-turn queue with preserved drafts; Chat/legacy-task navigation; explicit create_tasks acknowledgement")
    }

    @MainActor private static func makeStore(_ root: URL) throws -> TaskStore {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("TELOS_DATA_DIR", root.path, 1)
        // Load only the private persisted state, without scanning accessibility,
        // microphone, calendar or other real machine permissions.
        setenv("TELOS_PREVIEW", "longtext", 1)
        let store = TaskStore()
        unsetenv("TELOS_PREVIEW")
        precondition(store.dataDir.standardizedFileURL == root.standardizedFileURL)
        let worker = root.appendingPathComponent("fixture-worker.py")
        try Data(workerSource.utf8).write(to: worker, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: worker.path)
        let python = [FileManager.default.currentDirectoryPath + "/.runtime/venv/bin/python", "/usr/bin/python3", "/opt/homebrew/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }!
        store.chat.workerFixtureForTesting = (python: python, script: worker)
        return store
    }

    @MainActor private static func wait(_ label: String, bridge: CompanionBridge, timeout: TimeInterval = 8,
                                        until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            bridge.poll()
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Timed out: " + label)
    }

    private static func request(_ id: String, text: String? = nil, root: URL) throws {
        var value: [String: Any] = ["id": id]
        if let text { value["transcript"] = text }
        try JSONSerialization.data(withJSONObject: value).write(to: root.appendingPathComponent(id + ".request.json"), options: .atomic)
    }

    @discardableResult private static func marker(_ id: String, suffix: String, root: URL) throws -> URL {
        let file = root.appendingPathComponent(id + suffix)
        try Data().write(to: file, options: .atomic)
        return file
    }

    private static func status(_ id: String, root: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(id + ".status.json"))) as! [String: Any]
    }

    private static func payloads(_ root: URL) throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: root.appendingPathComponent("fixture-requests.jsonl"), encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    @MainActor private static func testTranscriptAndReplay(_ root: URL) async throws {
        let store = try makeStore(root)
        let id = UUID().uuidString
        let text = "我不想新建任务，请简洁介绍你自己。"
        var openedChat = 0
        var openedTasks: [UUID] = []
        let bridge = CompanionBridge(store: store, transcribe: { _, _ in preconditionFailure("An existing transcript must not be recognized again") },
                                     cancel: {}, show: { openedTasks.append($0) }, showChat: { openedChat += 1 }, automaticallyStart: false)
        precondition(bridge.timer == nil && !FileManager.default.fileExists(atPath: bridge.root.appendingPathComponent("heartbeat.json").path),
                     "Manual bridge fixtures must not poll or schedule a timer during initialization")
        try request(id, text: text, root: bridge.root)
        try marker(id, suffix: ".show", root: bridge.root)
        await wait("transcribed Chat reply", bridge: bridge) {
            store.chat.voiceTurn(for: id)?.state == "completed" && !store.chat.isRunning
        }
        bridge.poll()
        let turn = store.chat.voiceTurn(for: id)!
        precondition(store.tasks.isEmpty && store.chat.messages.count == 2,
                     "A pet utterance must add one user/reply pair in Chat, without a hidden standalone task")
        precondition(store.chat.messages[0].text == text && store.chat.messages[0].role == "user")
        precondition(store.chat.messages[0].id == turn.userMessageID && store.chat.messages[1].id == turn.responseMessageID)
        precondition(store.chat.messages[1].role == "assistant" && store.chat.messages[1].text == "Fixture reply: " + text)
        precondition(turn.language == "zh" && turn.requestID == id)
        precondition(openedChat == 1 && openedTasks.isEmpty, "A voice Chat .show marker must reveal Chat")
        let result = try status(id, root: bridge.root)
        precondition(result["source"] as? String == "chat" && result["state"] as? String == "completed")
        precondition(UUID(uuidString: result["conversation_id"] as? String ?? "") == store.chat.conversationID)
        precondition(UUID(uuidString: result["user_message_id"] as? String ?? "") == turn.userMessageID)
        precondition(UUID(uuidString: result["response_message_id"] as? String ?? "") == turn.responseMessageID)
        let sent = try payloads(root)
        precondition(sent.count == 1 && sent[0]["mode"] as? String == "chat" && sent[0]["voice"] as? Bool == true)
        precondition(sent[0]["voice_request_id"] as? String == id && sent[0]["voice_language"] as? String == "zh")
        precondition(UUID(uuidString: sent[0]["task_id"] as? String ?? "") == store.chat.conversationID)
        precondition(sent[0]["prompt"] as? String == text)

        try request(id, text: text, root: bridge.root)
        bridge.poll()
        let replayedPayloads = try payloads(root)
        precondition(store.chat.messages.count == 2 && replayedPayloads.count == 1,
                     "Replaying a recognized request must not append or launch another turn")
        let reopened = try makeStore(root)
        var reopenedChat = 0
        let afterRestart = CompanionBridge(store: reopened, transcribe: { _, _ in preconditionFailure("A replay must not recognize audio") },
                                          cancel: {}, show: { _ in preconditionFailure("A new voice request is not a task") },
                                          showChat: { reopenedChat += 1 }, automaticallyStart: false)
        try request(id, text: text, root: afterRestart.root)
        try marker(id, suffix: ".show", root: afterRestart.root)
        afterRestart.poll()
        precondition(reopened.chat.messages.count == 2 && reopened.chat.voiceTurn(for: id)?.userMessageID == turn.userMessageID)
        let restartedPayloads = try payloads(root)
        precondition(reopenedChat == 1 && restartedPayloads.count == 1,
                     "Restart must preserve voice identity and route its replay to the existing Chat")

        let legacyRequest = UUID().uuidString
        var legacy = Todo(title: "Existing legacy voice task", status: "completed")
        legacy.voiceRequestID = legacyRequest
        reopened.tasks.append(legacy)
        var oldTaskShown: UUID?
        let legacyBridge = CompanionBridge(store: reopened, transcribe: { _, _ in }, cancel: {},
                                          show: { oldTaskShown = $0 }, showChat: { reopenedChat += 1 }, automaticallyStart: false)
        try marker(legacyRequest, suffix: ".show", root: legacyBridge.root)
        legacyBridge.poll()
        precondition(oldTaskShown == legacy.id && reopenedChat == 1,
                     "Persisted pre-migration voice tasks must retain their original task navigation")
        let statusOnlyID = UUID().uuidString
        let rememberedRoute: [String: Any] = ["id": statusOnlyID, "source": "chat", "state": "completed",
                                               "conversation_id": reopened.chat.conversationID.uuidString,
                                               "user_message_id": statusOnlyID]
        try JSONSerialization.data(withJSONObject: rememberedRoute).write(to: legacyBridge.root.appendingPathComponent(statusOnlyID + ".status.json"))
        try marker(statusOnlyID, suffix: ".show", root: legacyBridge.root)
        legacyBridge.poll()
        precondition(reopenedChat == 2 && oldTaskShown == legacy.id,
                     "A persisted Chat status must preserve its navigation even without an in-memory voice turn")
    }

    @MainActor private static func testRecognitionAndLateCancellation(_ root: URL) async throws {
        let store = try makeStore(root)
        var callbacks: [([String: Any]) -> Void] = []
        var cancelled = 0
        let bridge = CompanionBridge(store: store, transcribe: { _, completion in callbacks.append(completion) },
                                     cancel: { cancelled += 1 }, show: { _ in }, automaticallyStart: false)
        let first = UUID().uuidString
        try Data(repeating: 0, count: 128).write(to: bridge.root.appendingPathComponent(first + ".wav"))
        try request(first, root: bridge.root)
        bridge.poll()
        precondition(callbacks.count == 1 && store.chat.messages.isEmpty)
        callbacks[0](["stage": "recognizing"])
        precondition(store.chat.messages.isEmpty, "ASR progress must not start an agent turn")
        callbacks[0](["text": "Hello Pico, please introduce yourself."])
        await wait("fallback recognition Chat reply", bridge: bridge) { store.chat.voiceTurn(for: first)?.state == "completed" && !store.chat.isRunning }
        callbacks[0](["text": "A repeated completion must be ignored."])
        bridge.poll()
        let sent = try payloads(root)
        precondition(store.chat.messages.count == 2 && sent.count == 1 && sent[0]["voice_language"] as? String == "en",
                     "A final ASR callback must produce exactly one English Chat turn")
        let later = UUID().uuidString
        try Data(repeating: 0, count: 128).write(to: bridge.root.appendingPathComponent(later + ".wav"))
        try request(later, root: bridge.root)
        bridge.poll()
        precondition(callbacks.count == 2)
        try marker(later, suffix: ".cancel", root: bridge.root)
        bridge.poll()
        callbacks[1](["text": "This cancelled recognition arrived late."])
        bridge.poll()
        precondition(cancelled == 1 && store.chat.voiceTurn(for: later) == nil && store.chat.messages.count == 2)
        let cancelledStatus = try status(later, root: bridge.root)
        let afterCancellation = try payloads(root)
        precondition(cancelledStatus["state"] as? String == "cancelled")
        precondition(afterCancellation.count == 1 && store.tasks.isEmpty,
                     "A late ASR callback after cancellation must not create Chat messages or tasks")

        let runningID = UUID().uuidString
        try request(runningID, text: "Hold typed input while this voice turn is cancelled", root: bridge.root)
        await wait("active voice before cancellation", bridge: bridge) { store.chat.voiceTurn(for: runningID) != nil && store.chat.isRunning }
        try marker(runningID, suffix: ".cancel", root: bridge.root)
        bridge.poll()
        precondition(!store.chat.isRunning && store.chat.voiceTurn(for: runningID)?.state == "cancelled",
                     "Cancelling an accepted voice request must stop its matching Chat worker")
    }

    @MainActor private static func testTypedQueueAndDrafts(_ root: URL) async throws {
        let store = try makeStore(root)
        var openedChat = 0
        let bridge = CompanionBridge(store: store, transcribe: { _, _ in }, cancel: {}, show: { _ in },
                                     showChat: { openedChat += 1 }, automaticallyStart: false)
        precondition(store.chat.send("Hold typed input"))
        await wait("typed fixture starts", bridge: bridge) { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        let typedResponse = store.chat.responseMessageID
        store.chat.draft = "Keep my unsent draft"
        let attachment = ComposerFile(name: "unsent.txt", path: root.appendingPathComponent("unsent.txt").path)
        store.chat.files = [attachment]
        let cancelledID = UUID().uuidString
        try request(cancelledID, text: "A cancelled queued voice request", root: bridge.root)
        bridge.poll()
        let pending = bridge.root.appendingPathComponent(cancelledID + ".chat-pending.json")
        precondition(FileManager.default.fileExists(atPath: pending.path) && store.chat.voiceTurn(for: cancelledID) == nil)
        precondition(store.chat.responseMessageID == typedResponse && store.chat.messages.count == 1)
        try marker(cancelledID, suffix: ".cancel", root: bridge.root)
        bridge.poll()
        precondition(!FileManager.default.fileExists(atPath: pending.path) && store.chat.isRunning && store.chat.responseMessageID == typedResponse,
                     "Cancelling one queued voice request must leave the typed worker running")
        precondition(store.chat.draft == "Keep my unsent draft" && store.chat.files.map(\.path) == [attachment.path])

        let acceptedID = UUID().uuidString
        let voiceText = "Continue the voice conversation after the typed reply."
        try request(acceptedID, text: voiceText, root: bridge.root)
        try marker(acceptedID, suffix: ".show", root: bridge.root)
        bridge.poll()
        precondition(FileManager.default.fileExists(atPath: bridge.root.appendingPathComponent(acceptedID + ".chat-pending.json").path))
        precondition(openedChat == 1, "A queued voice request must open Chat before the typed worker finishes")
        try Data().write(to: root.appendingPathComponent("fixture-release"))
        await wait("typed reply then queued voice", bridge: bridge) { store.chat.voiceTurn(for: acceptedID)?.state == "completed" && !store.chat.isRunning }
        precondition(store.chat.draft == "Keep my unsent draft" && store.chat.files.map(\.path) == [attachment.path],
                     "Sending a queued voice turn must preserve an unrelated typed draft and its attachments")
        precondition(store.chat.voiceTurn(for: cancelledID) == nil && store.chat.messages.count == 4 && store.tasks.isEmpty)
        let sent = try payloads(root)
        precondition(sent.count == 2 && sent[0]["voice"] as? Bool != true && sent[1]["voice_request_id"] as? String == acceptedID)
        precondition(sent[1]["prompt"] as? String == voiceText,
                     "Voice input must not send the unsent typed draft or attach its files")
    }

    @MainActor private static func testPendingRestart(_ root: URL) async throws {
        let store = try makeStore(root)
        let bridge = CompanionBridge(store: store, transcribe: { _, _ in }, cancel: {}, show: { _ in }, automaticallyStart: false)
        precondition(store.chat.send("Hold typed input before restart"))
        await wait("typed fixture before restart", bridge: bridge) { FileManager.default.fileExists(atPath: root.appendingPathComponent("fixture-requests.jsonl").path) }
        let id = UUID().uuidString
        try request(id, text: "Please keep this queued voice request after restart.", root: bridge.root)
        bridge.poll()
        let pending = bridge.root.appendingPathComponent(id + ".chat-pending.json")
        precondition(FileManager.default.fileExists(atPath: pending.path) && store.chat.voiceTurn(for: id) == nil)
        store.chat.stop()
        let restarted = try makeStore(root)
        var shown = 0
        let reopened = CompanionBridge(store: restarted, transcribe: { _, _ in preconditionFailure("A recognized queue must not repeat ASR after restart") },
                                       cancel: {}, show: { _ in }, showChat: { shown += 1 }, automaticallyStart: false)
        try marker(id, suffix: ".show", root: reopened.root)
        await wait("queued voice restart recovery", bridge: reopened) { restarted.chat.voiceTurn(for: id)?.state == "completed" && !restarted.chat.isRunning }
        reopened.poll()
        precondition(!FileManager.default.fileExists(atPath: pending.path) && shown == 1 && restarted.tasks.isEmpty)
        precondition(restarted.chat.messages.filter { $0.id == UUID(uuidString: id) }.count == 1)
        let sent = try payloads(root)
        precondition(sent.filter { $0["voice_request_id"] as? String == id }.count == 1,
                     "A durable queued transcript must launch once after restart")
        try request(id, text: "Please keep this queued voice request after restart.", root: reopened.root)
        reopened.poll()
        let replayed = try payloads(root)
        precondition(replayed.count == sent.count, "Replaying a recovered queue must remain idempotent")
    }

    @MainActor private static func testActiveVoiceRestart(_ root: URL, checkpoint: Bool) async throws {
        let store = try makeStore(root)
        let bridge = CompanionBridge(store: store, transcribe: { _, _ in }, cancel: {}, show: { _ in }, automaticallyStart: false)
        let id = UUID().uuidString
        try request(id, text: "Hold typed input for active voice crash recovery", root: bridge.root)
        await wait("accepted active voice", bridge: bridge) {
            store.chat.isRunning && store.chat.voiceTurn(for: id)?.state == "working"
        }
        bridge.poll()
        let pending = bridge.root.appendingPathComponent(id + ".chat-pending.json")
        let snapshotURL = root.appendingPathComponent("chat.json")
        let statusURL = bridge.root.appendingPathComponent(id + ".status.json")
        let interrupted = try Data(contentsOf: snapshotURL)
        let interruptedStatus = try Data(contentsOf: statusURL)
        let saved = try JSONSerialization.jsonObject(with: interrupted) as! [String: Any]
        let waiting = try status(id, root: bridge.root)
        precondition(!FileManager.default.fileExists(atPath: pending.path),
                     "This fixture must represent an accepted turn whose pending marker was already removed")
        precondition(waiting["source"] as? String == "chat" && waiting["state"] as? String == "working")
        precondition(saved["activeRunID"] as? String != nil && saved["activeVoiceRequestID"] as? String == id)

        // Stop only the private fixture process for cleanup, then restore its
        // last running snapshot to reproduce an app crash, not user cancellation.
        store.chat.stop()
        try interrupted.write(to: snapshotURL, options: .atomic)
        try interruptedStatus.write(to: statusURL, options: .atomic)
        if checkpoint {
            let file = root.appendingPathComponent("chats/" + store.chat.conversationID.uuidString.lowercased() + "/last-turn.json")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let value: [String: Any] = ["run_id": saved["activeRunID"] as! String,
                                        "event": ["type": "done", "text": "Recovered checkpoint reply.", "status": "ready", "summary": "Recovered"]]
            try JSONSerialization.data(withJSONObject: value).write(to: file, options: .atomic)
        }
        let restarted = try makeStore(root)
        let recovered = CompanionBridge(store: restarted, transcribe: { _, _ in preconditionFailure("An accepted turn must not repeat ASR") },
                                        cancel: {}, show: { _ in }, automaticallyStart: false)
        recovered.poll()
        let result = try status(id, root: recovered.root)
        let expectedState = checkpoint ? "completed" : "cancelled"
        precondition(restarted.chat.voiceTurn(for: id)?.state == expectedState && !restarted.chat.isRunning)
        precondition(result["source"] as? String == "chat" && result["state"] as? String == expectedState,
                     "Restart must replace the pet's stale working status with the recovered Chat terminal state")
        precondition(result["text"] as? String == restarted.chat.voiceTurn(for: id)?.text)
        precondition(restarted.chat.messages.filter { $0.role == "user" && $0.id == UUID(uuidString: id) }.count == 1)
        precondition(restarted.chat.messages.count == (checkpoint ? 2 : 1) && restarted.tasks.isEmpty)
        if checkpoint {
            precondition(restarted.chat.messages.last?.text == "Recovered checkpoint reply.")
            precondition(UUID(uuidString: result["response_message_id"] as? String ?? "") == restarted.chat.messages.last?.id)
        }
        let beforeReplay = try payloads(root)
        precondition(beforeReplay.count == 1, "Recovery must not relaunch an already accepted voice request")
        try request(id, text: "Hold typed input for active voice crash recovery", root: recovered.root)
        recovered.poll()
        let reopenedAgain = try makeStore(root)
        let again = CompanionBridge(store: reopenedAgain, transcribe: { _, _ in }, cancel: {}, show: { _ in }, automaticallyStart: false)
        again.poll()
        let afterReplay = try payloads(root)
        precondition(afterReplay.count == 1 && reopenedAgain.chat.messages.count == restarted.chat.messages.count,
                     "Repeating an accepted request or reopening its recovered state must not duplicate any Chat row")
    }

    @MainActor private static func testTerminalQueueLeftovers(_ root: URL) throws {
        for terminal in ["cancelled", "error"] {
            let directory = root.appendingPathComponent(terminal)
            let store = try makeStore(directory)
            let bridge = CompanionBridge(store: store, transcribe: { _, _ in preconditionFailure("A terminal queued request must not recognize again") },
                                         cancel: {}, show: { _ in }, automaticallyStart: false)
            let id = UUID().uuidString
            let pending = bridge.root.appendingPathComponent(id + ".chat-pending.json")
            // Reconstruct the durable leftovers after a failed pending-file
            // deletion: its terminal status already committed, but no turn ran.
            let value: [String: Any] = ["id": id, "text": "Do not replay this finished queue request.",
                                        "language": "en", "created": Date().timeIntervalSince1970]
            let pendingData = try JSONSerialization.data(withJSONObject: value)
            let result: [String: Any] = ["id": id, "source": "chat", "state": terminal, "text": "Finished without sending.",
                                         "conversation_id": store.chat.conversationID.uuidString, "user_message_id": id]
            try pendingData.write(to: pending, options: .atomic)
            try JSONSerialization.data(withJSONObject: result).write(to: bridge.root.appendingPathComponent(id + ".status.json"), options: .atomic)
            bridge.poll()
            precondition(store.chat.voiceTurn(for: id) == nil && store.chat.messages.isEmpty && !store.chat.isRunning,
                         "A leftover pending file with a terminal status must not be accepted into Chat")
            let firstPayloads = try payloads(directory)
            let firstStatus = try status(id, root: bridge.root)
            precondition(firstPayloads.isEmpty && firstStatus["state"] as? String == terminal)

            // The same stale file may remain through another startup if removal
            // keeps failing. A replayed request must still not override terminal.
            try pendingData.write(to: pending, options: .atomic)
            let restarted = try makeStore(directory)
            let reopened = CompanionBridge(store: restarted, transcribe: { _, _ in }, cancel: {}, show: { _ in }, automaticallyStart: false)
            try request(id, text: "Do not replay this finished queue request.", root: reopened.root)
            reopened.poll()
            let afterRestart = try payloads(directory)
            let reopenedStatus = try status(id, root: reopened.root)
            precondition(restarted.chat.voiceTurn(for: id) == nil && restarted.chat.messages.isEmpty && afterRestart.isEmpty)
            precondition(reopenedStatus["state"] as? String == terminal && restarted.tasks.isEmpty,
                         "Terminal queue state must survive app restart without restarting the model")
        }
    }

    @MainActor private static func testExplicitTaskTool(_ root: URL) async throws {
        let store = try makeStore(root)
        let bridge = CompanionBridge(store: store, transcribe: { _, _ in }, cancel: {}, show: { _ in }, automaticallyStart: false)
        let id = UUID().uuidString
        try request(id, text: "Create explicit task with the task tool", root: bridge.root)
        await wait("explicit create_tasks tool roundtrip", bridge: bridge) { store.chat.voiceTurn(for: id)?.state == "completed" && !store.chat.isRunning }
        precondition(store.tasks.count == 1 && store.chat.messages.count == 2)
        let task = store.tasks[0]
        precondition(task.title == "Fixture follow-up" && task.status == "pending" && task.voiceRequestID == nil)
        precondition(task.sourceTaskID == store.chat.conversationID && task.creationRequest == store.chat.voiceTurn(for: id)?.userMessageID,
                     "An explicit task tool call must belong to the same Chat request, not a hidden voice task")
        let ack = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixture-task-ack.json"))) as! [String: Any]
        precondition(ack["status"] as? String == "saved_not_started" && (ack["tasks"] as? [[String: Any]])?.count == 1)
        precondition(store.chat.messages.last?.text == "Saved the explicit follow-up task.")
    }

    private static let workerSource = #"""
import json
import os
import sys
import time
from pathlib import Path

root = Path(os.environ["TELOS_DATA_DIR"])
request = json.loads(sys.stdin.readline())
with (root / "fixture-requests.jsonl").open("a", encoding="utf-8") as output:
    output.write(json.dumps(request, ensure_ascii=False) + "\n")
    output.flush()
prompt = request.get("prompt", "")
if prompt.startswith("Hold typed input"):
    print(json.dumps({"type": "phase", "status": "working"}), flush=True)
    deadline = time.monotonic() + 20
    while not (root / "fixture-release").exists() and time.monotonic() < deadline:
        time.sleep(0.01)
if prompt.startswith("Create explicit task"):
    print(json.dumps({"type": "create_tasks", "request_id": "fixture-task-tool", "tasks": [
        {"title": "Fixture follow-up", "instructions": "Complete this isolated local fixture task later."}
    ]}), flush=True)
    ack = json.loads(sys.stdin.readline())
    (root / "fixture-task-ack.json").write_text(json.dumps(ack), encoding="utf-8")
    text = "Saved the explicit follow-up task."
else:
    text = "Fixture reply: " + prompt
print(json.dumps({"type": "done", "text": text, "status": "ready", "summary": "Fixture complete"}, ensure_ascii=False), flush=True)
"""#
}
