import Foundation

/// Isolated pipe-level voice tests. The fixture emits deterministic NDJSON;
/// it never loads the agent runtime, reads credentials or calls a provider.
@main struct PicoVoiceChatStoreTests {
    @MainActor static func main() throws {
        #if TELOS_TEST
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicoVoiceChat-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("worker.py")
        try #"""
import json, os, pathlib, sys, time
request = json.loads(sys.stdin.readline())
root = pathlib.Path(os.environ['TELOS_DATA_DIR'])
with (root/'fixture-requests.jsonl').open('a') as output:
    output.write(json.dumps(request)+'\n')
def emit(kind, **values):
    print(json.dumps(dict(type=kind, **values)), flush=True)
prompt = request['prompt']
emit('phase', status='working')
if prompt in ('hold', 'typed hold'):
    emit('delta', text='Exact partial')
    time.sleep(20)
elif prompt == 'error':
    emit('error', text='Exact fixture failure')
elif prompt == 'partial error':
    emit('delta', text='Unfinished text')
    emit('error', text='Exact partial failure')
elif prompt == 'abrupt':
    emit('delta', text='Interrupted output')
elif prompt == 'approval':
    emit('approval', approval_id='fixture', action_hash='hash', expires_at=time.time()+60,
         app='Fixture', text='Exact confirmation', details='Local fixture only', risk='action')
    reply = json.loads(sys.stdin.readline())
    emit('approval_resolved', approval_id='fixture')
    emit('done', text='Approved fixture result' if reply['decision']=='approve' else 'Declined fixture result', status='ready')
elif prompt == 'persist failure':
    (root/'chat.json').unlink()
    (root/'chat.json').mkdir()
    emit('done', text='A result that could not be saved', status='ready')
else:
    emit('delta', text='Not the final answer')
    emit('done', text='Exact final answer' if prompt != 'needs input' else 'Exact needed decision',
         status='ready' if prompt != 'needs input' else 'needs_input')
    if prompt == 'lingering final': time.sleep(0.5)
"""#.write(to: fixture, atomically: true, encoding: .utf8)
        let python = ProcessInfo.processInfo.environment["PICO_TEST_PYTHON"] ?? "/usr/bin/python3"
        func make(_ name: String) -> PicoChatStore {
            let store = PicoChatStore(dataDir: root.appendingPathComponent(name))
            store.workerFixtureForTesting = (python, fixture)
            return store
        }
        func wait(_ predicate: () -> Bool) {
            let deadline = Date().addingTimeInterval(6)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            precondition(predicate(), "The isolated voice worker did not reach its expected state")
        }

        let chat = make("normal"), id = UUID().uuidString
        chat.draft = "Unsent typed draft"
        chat.files = [ComposerFile(name: "Unsent.txt", path: "/not-read-by-voice")]
        precondition(chat.sendVoice("normal", requestID: id.lowercased(), language: "zh"))
        precondition(chat.messages.count == 1 && chat.messages[0].id == UUID(uuidString: id))
        precondition(chat.messages[0].origin == "voice" && chat.messages[0].role == "user")
        precondition(chat.sendVoice("must not resend", requestID: id, language: "en"))
        let busyID = UUID().uuidString
        precondition(!chat.sendVoice("not accepted while busy", requestID: busyID, language: "en"))
        precondition(chat.voiceTurn(for: busyID) == nil)
        wait { !chat.isRunning }
        let turn = chat.voiceTurn(for: id)!
        precondition(turn.state == "completed" && turn.text == "Exact final answer" && turn.language == "zh")
        precondition(chat.messages.count == 2 && chat.messages[1].id == turn.responseMessageID)
        precondition(chat.messages[1].text == turn.text && turn.userMessageID == UUID(uuidString: id))
        precondition(chat.draft == "Unsent typed draft" && chat.files.first?.name == "Unsent.txt")
        let payloads = try String(contentsOf: chat.dataDir.appendingPathComponent("fixture-requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        precondition(payloads.count == 1 && payloads[0]["mode"] as? String == "chat")
        precondition(payloads[0]["voice"] as? Bool == true && payloads[0]["voice_language"] as? String == "zh")
        precondition(payloads[0]["voice_request_id"] as? String == id)
        precondition(payloads[0]["message_id"] as? String == id && payloads[0]["task_id"] as? String == chat.conversationID.uuidString)
        precondition(!FileManager.default.fileExists(atPath: chat.dataDir.appendingPathComponent("tasks.json").path))
        let reloaded = PicoChatStore(dataDir: chat.dataDir)
        precondition(reloaded.voiceTurn(for: id)?.responseMessageID == turn.responseMessageID)
        precondition(reloaded.sendVoice("no duplicate after restart", requestID: id, language: "en"))
        precondition(reloaded.messages.count == 2 && !reloaded.isRunning)

        let needsID = UUID().uuidString
        precondition(chat.sendVoice("needs input", requestID: needsID, language: "en"))
        wait { !chat.isRunning }
        precondition(chat.voiceTurn(for: needsID)?.state == "needs_input")
        precondition(chat.voiceTurn(for: needsID)?.text == chat.messages.last?.text)
        let oldAnswer = chat.messages.last!.id
        let errorID = UUID().uuidString
        precondition(chat.sendVoice("error", requestID: errorID, language: "en"))
        wait { !chat.isRunning }
        precondition(chat.voiceTurn(for: errorID)?.state == "error")
        precondition(chat.voiceTurn(for: errorID)?.text == "Exact fixture failure")
        precondition(chat.voiceTurn(for: errorID)?.responseMessageID == nil)
        precondition(chat.messages.last?.id != oldAnswer && chat.messages.last?.role == "user")
        let partialError = UUID().uuidString
        precondition(chat.sendVoice("partial error", requestID: partialError, language: "en"))
        wait { !chat.isRunning }
        precondition(chat.voiceTurn(for: partialError)?.state == "error")
        precondition(chat.voiceTurn(for: partialError)?.responseMessageID == chat.messages.last?.id)
        precondition(chat.messages.last?.text == "Unfinished text")

        let hold = UUID().uuidString
        precondition(chat.sendVoice("hold", requestID: hold, language: "en"))
        wait { chat.voiceTurn(for: hold)?.state == "working" && !chat.stream.isEmpty }
        chat.stopVoice(requestID: UUID().uuidString)
        precondition(chat.isRunning)
        chat.stopVoice(requestID: hold.lowercased())
        precondition(!chat.isRunning && chat.voiceTurn(for: hold)?.state == "cancelled")
        precondition(chat.voiceTurn(for: hold)?.responseMessageID == chat.messages.last?.id)
        precondition(chat.voiceTurn(for: hold)?.text == chat.messages.last?.text)
        let users = chat.messages.filter { $0.role == "user" }.count
        chat.retry()
        wait { chat.isRunning && !chat.stream.isEmpty }
        precondition(chat.messages.filter { $0.role == "user" }.count == users)
        chat.stopVoice(requestID: hold)
        precondition(!chat.isRunning)
        precondition(chat.send("typed hold"))
        wait { chat.isRunning && !chat.stream.isEmpty }
        chat.stopVoice(requestID: hold)
        precondition(chat.isRunning, "An old pet request must not stop a typed turn")
        chat.stop()

        let lingering = make("lingering"), lingeringID = UUID().uuidString
        precondition(lingering.sendVoice("lingering final", requestID: lingeringID, language: "en"))
        wait { lingering.voiceTurn(for: lingeringID)?.state == "completed" }
        precondition(lingering.isRunning, "A final event does not mean the process has exited")
        precondition(!lingering.sendVoice("do not overlap", requestID: UUID().uuidString, language: "en"))
        lingering.stopVoice(requestID: lingeringID)
        precondition(lingering.voiceTurn(for: lingeringID)?.state == "completed")
        wait { !lingering.isRunning }

        let approvalChat = make("approval"), approvalID = UUID().uuidString
        precondition(approvalChat.sendVoice("approval", requestID: approvalID, language: "en"))
        wait { approvalChat.approval != nil }
        precondition(approvalChat.voiceTurn(for: approvalID)?.state == "awaiting_approval")
        approvalChat.decide(approve: true)
        wait { !approvalChat.isRunning }
        precondition(approvalChat.voiceTurn(for: approvalID)?.text == "Approved fixture result")
        precondition(approvalChat.voiceTurn(for: approvalID)?.responseMessageID == approvalChat.messages.last?.id)

        let failing = make("initial-save-failure"), failedID = UUID().uuidString
        try FileManager.default.createDirectory(at: failing.dataDir.appendingPathComponent("chat.json"), withIntermediateDirectories: true)
        failing.draft = "Keep this"
        precondition(!failing.sendVoice("not saved", requestID: failedID, language: "en"))
        precondition(failing.voiceTurn(for: failedID) == nil && failing.messages.isEmpty && failing.draft == "Keep this")
        let terminalFailure = make("terminal-save-failure"), terminalID = UUID().uuidString
        precondition(terminalFailure.sendVoice("persist failure", requestID: terminalID, language: "en"))
        wait { !terminalFailure.isRunning }
        precondition(terminalFailure.voiceTurn(for: terminalID)?.state == "error")
        precondition(terminalFailure.voiceTurn(for: terminalID)?.responseMessageID == nil)

        try recovery(in: root.appendingPathComponent("checkpoint"), completed: true)
        try recovery(in: root.appendingPathComponent("interrupted"), completed: false)
        print("PASS: one-to-one voice Chat rows, identical final text, durable request deduplication, unchanged drafts/files, busy backpressure, spoken payload, exact cancellation/approval, no old-answer fallback, process-final gap, failed-save safety and checkpoint recovery")
        #else
        fatalError("Compile this isolated fixture test with -DTELOS_TEST")
        #endif
    }

    @MainActor private static func recovery(in root: URL, completed: Bool) throws {
        let conversation = UUID(), request = UUID(), run = UUID()
        let messages = [Message(role: "assistant", text: "Old unrelated reply"),
                        Message(id: request, role: "user", text: "Voice before crash", origin: "voice")]
        let turn = PicoVoiceChatTurn(requestID: request.uuidString, userMessageID: request,
                                    language: "zh", state: "working", text: "")
        let serialized = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messages))
        let turns = try JSONSerialization.jsonObject(with: JSONEncoder().encode([request.uuidString: turn]))
        let directory = root.appendingPathComponent("chats/" + conversation.uuidString.lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot: [String: Any] = ["conversationID": conversation.uuidString, "messages": serialized,
                                      "artifacts": [], "status": "working", "activeRunID": run.uuidString,
                                      "voiceTurns": turns, "activeVoiceRequestID": request.uuidString]
        try JSONSerialization.data(withJSONObject: snapshot).write(to: root.appendingPathComponent("chat.json"))
        if completed {
            let checkpoint: [String: Any] = ["run_id": run.uuidString,
                                            "event": ["type": "done", "status": "ready", "text": "Exact recovered reply"]]
            try JSONSerialization.data(withJSONObject: checkpoint).write(to: directory.appendingPathComponent("last-turn.json"))
        }
        let restored = PicoChatStore(dataDir: root)
        let result = restored.voiceTurn(for: request.uuidString)!
        precondition(result.state == (completed ? "completed" : "cancelled"))
        if completed {
            precondition(result.text == "Exact recovered reply" && result.responseMessageID == run)
            precondition(restored.messages.last?.id == run && restored.messages.last?.text == result.text)
        } else {
            precondition(result.responseMessageID == nil && result.text != "Old unrelated reply")
        }
        let again = PicoChatStore(dataDir: root)
        precondition(again.messages.map(\.id) == restored.messages.map(\.id))
        precondition(again.voiceTurn(for: request.uuidString)?.state == result.state)
    }
}
