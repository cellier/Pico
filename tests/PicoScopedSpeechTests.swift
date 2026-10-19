import Foundation

@MainActor enum PicoScopedSpeechTests {
    private static func ready(_ client: PicoRealtime) { client.injectDiagnosticEvent(["type": "session.updated"]) }
    private static func created(_ client: PicoRealtime, _ id: String) {
        client.injectDiagnosticEvent(["type": "response.created", "response": ["id": id, "metadata": ["scope_id": UUID().uuidString]]])
    }
    private static func done(_ client: PicoRealtime, _ id: String, status: String = "completed", calls: [[String: Any]] = []) {
        client.injectDiagnosticEvent(["type": "response.done", "response": ["id": id, "status": status, "output": calls]])
    }
    private static func audio(_ client: PicoRealtime, _ id: String) {
        client.injectDiagnosticEvent(["type": "response.audio.delta", "response_id": id, "delta": Data([0, 1]).base64EncodedString()])
    }
    private static func vad(_ client: PicoRealtime, _ type: String, item: String) {
        client.injectDiagnosticEvent(["type": "input_audio_buffer.speech_" + type, "item_id": item])
    }
    private static func asr(_ client: PicoRealtime, _ text: String, item: String) {
        client.injectDiagnosticEvent(["type": "conversation.item.input_audio_transcription.completed", "item_id": item, "transcript": text])
    }
    private static func appItems(_ events: [[String: Any]]) -> [[String: Any]] {
        events.filter { $0["type"] as? String == "conversation.item.create" }.compactMap { $0["item"] as? [String: Any] }
            .filter { ($0["id"] as? String)?.hasPrefix("pico_app_") == true }
    }
    private static func deleted(_ events: [[String: Any]]) -> [String] {
        events.filter { $0["type"] as? String == "conversation.item.delete" }.compactMap { $0["item_id"] as? String }
    }
    static func run() async {
        let client = PicoRealtime(), scope = UUID()
        var events: [[String: Any]] = [], starts: [(String, UUID?)] = []
        client.onSentEvent = { events.append($0) }
        client.onResponseStarted = { starts.append(($0, client.scriptScope(for: $0))) }
        ready(client)
        precondition(client.requestSpokenTurn("Synthetic approved chunk.", scopeID: scope))
        let ownID = appItems(events)[0]["id"] as! String
        let content = appItems(events)[0]["content"] as! [[String: Any]]
        precondition((content[0]["text"] as! String).contains("ONE RESPONSE ONLY"))
        created(client, "app-response")
        precondition(starts.count == 1 && starts[0].1 == scope, "the local scope must be installed before the start callback; remote metadata is ignored")
        done(client, "app-response"); done(client, "app-response")
        precondition(deleted(events) == [ownID], "a terminal event deletes only this app's user item once")
        vad(client, "started", item: "live-normal"); vad(client, "stopped", item: "live-normal")
        created(client, "normal-answer")
        asr(client, "A real question arriving after response.created", item: "live-normal")
        precondition(starts.last?.0 == "normal-answer" && starts.last?.1 == nil)
        done(client, "normal-answer"); client.stop(); client.stop()
        precondition(deleted(events) == [ownID], "automatic live audio and assistant items must never be deleted")
        created(client, "late-after-stop")
        precondition(starts.count == 2 && client.scriptScope(for: "late-after-stop") == nil)

        // An app response already has a known identity when VAD begins: ordinary QA
        // remains automatic, with no repair request and no inherited presentation scope.
        let active = PicoRealtime(); var activeEvents: [[String: Any]] = [], played: [String] = [], activeScopes: [UUID?] = []
        active.onSentEvent = { activeEvents.append($0) }; active.onAudio = { _, id in played.append(id) }
        active.onResponseStarted = { activeScopes.append(active.scriptScope(for: $0)) }
        ready(active); precondition(active.requestSpokenTurn("Interrupted chunk.", scopeID: scope)); created(active, "known-app")
        vad(active, "started", item: "real-question"); audio(active, "known-app")
        vad(active, "stopped", item: "real-question"); created(active, "automatic-qa")
        asr(active, "What can you do without slides?", item: "real-question"); audio(active, "automatic-qa")
        done(active, "known-app", status: "cancelled"); done(active, "automatic-qa")
        precondition(played == ["automatic-qa"] && activeScopes.count == 2 && activeScopes[1] == nil)
        precondition(appItems(activeEvents).count == 1, "a normal automatic answer must never be supplemented or replayed merely because ASR is late")
        active.stop()

        // A tool-only response and its eventual spoken follow-up share the same local
        // scope, even though each has a different server response ID.
        let tools = PicoRealtime(); var toolEvents: [[String: Any]] = [], toolScopes: [UUID?] = []
        tools.onSentEvent = { toolEvents.append($0) }; tools.onResponseStarted = { toolScopes.append(tools.scriptScope(for: $0)) }
        tools.presentationControl = { _ in #"{"applied":true}"# }
        ready(tools); precondition(tools.requestSpokenTurn("Synthetic tool-using chunk.", scopeID: scope)); created(tools, "tool-first")
        let call: [String: Any] = ["type": "function_call", "name": "control_presentation", "call_id": "scope-tool", "arguments": #"{"action":"pause"}"#]
        done(tools, "tool-first", calls: [call])
        precondition(deleted(toolEvents).isEmpty, "tool-only completion must retain the original scoped instruction for its spoken follow-up")
        created(tools, "tool-spoken"); done(tools, "tool-spoken")
        precondition(toolScopes.count == 2 && toolScopes.allSatisfy { $0 == scope })
        precondition(deleted(toolEvents).count == 1, "tool aliases cannot repeatedly delete their shared app instruction")
        tools.stop()
        let silent = PicoRealtime(); var silentEvents: [[String: Any]] = []
        silent.onSentEvent = { silentEvents.append($0) }; silent.presentationControl = { _ in #"{"applied":true}"# }
        ready(silent); precondition(silent.requestSpokenTurn("Synthetic resume control.", scopeID: scope)); created(silent, "silent-tool")
        let resume: [String: Any] = ["type": "function_call", "name": "control_presentation", "call_id": "scope-resume", "arguments": #"{"action":"resume"}"#]
        done(silent, "silent-tool", calls: [resume])
        precondition(deleted(silentEvents).count == 1 && silent.canRequestTurn, "a silent tool result has no spoken follow-up and must delete its app instruction immediately")
        silent.stop(); precondition(deleted(silentEvents).count == 1)

        // In-flight app request collides with VAD before a response ID is known. Neither
        // the ambiguous response nor an old transcript may advance or read the script.
        let race = PicoRealtime(); var raceEvents: [[String: Any]] = [], raceStarts: [String] = [], racePlayed: [String] = []
        race.onSentEvent = { raceEvents.append($0) }; race.onResponseStarted = { raceStarts.append($0) }
        race.onAudio = { _, id in racePlayed.append(id) }
        ready(race); precondition(race.requestSpokenTurn("Stale opening must not repeat.", scopeID: scope))
        vad(race, "started", item: "current-live"); created(race, "ambiguous-old"); audio(race, "ambiguous-old")
        asr(race, "An unrelated older transcript", item: "older-live")
        vad(race, "stopped", item: "current-live"); done(race, "ambiguous-old", status: "cancelled")
        precondition(appItems(raceEvents).count == 1 && !race.canRequestTurn && raceStarts.isEmpty && racePlayed.isEmpty)
        asr(race, "Can you answer my current question?", item: "current-live")
        precondition(appItems(raceEvents).count == 2 && raceStarts.isEmpty)
        let repair = (appItems(raceEvents)[1]["content"] as! [[String: Any]])[0]["text"] as! String
        precondition(repair.contains("Can you answer my current question?") && !repair.contains("Stale opening must not repeat"))
        asr(race, "Can you answer my current question?", item: "current-live")
        created(race, "repaired-answer"); audio(race, "ambiguous-old"); audio(race, "repaired-answer")
        precondition(race.scriptScope(for: "repaired-answer") == nil && racePlayed == ["repaired-answer"])
        done(race, "repaired-answer"); race.stop()
        precondition(appItems(raceEvents).count == 2 && Set(deleted(raceEvents)) == Set(appItems(raceEvents).compactMap { $0["id"] as? String }))

        // ASR may precede the cancellation acknowledgement. Repair waits for both, and a
        // local resume-only action suppresses it rather than answering “continue” twice.
        for suppress in [false, true] {
            let pending = PicoRealtime(); var sent: [[String: Any]] = []
            pending.onSentEvent = { sent.append($0) }
            if suppress { pending.onTranscript = { role, _, _ in if role == "other" { pending.suppressReplyForPresentationResume() } } }
            ready(pending); precondition(pending.requestSpokenTurn("Synthetic pending chunk.", scopeID: scope))
            vad(pending, "started", item: "early-asr"); vad(pending, "stopped", item: "early-asr")
            asr(pending, suppress ? "继续" : "Please answer this question", item: "early-asr")
            precondition(appItems(sent).count == 1)
            precondition(!pending.canRequestTurn && !sent.contains { $0["type"] as? String == "response.cancel" }, "wait for a real response ID instead of cancelling an idle inference")
            created(pending, "early-auto")
            pending.injectDiagnosticEvent(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_value", "param": "response.cancel", "message": "Conversation has no active response."]])
            precondition(appItems(sent).count == (suppress ? 1 : 2))
            if suppress { precondition(pending.canRequestTurn) }
            pending.stop(); pending.onTranscript = nil
            precondition(deleted(sent).count == appItems(sent).count)
        }
        let uncertain = PicoRealtime(); var uncertaintyErrors: [String] = [], uncertainEvents: [[String: Any]] = []
        uncertain.onError = { uncertaintyErrors.append($0) }; uncertain.onSentEvent = { uncertainEvents.append($0) }
        ready(uncertain); precondition(uncertain.requestSpokenTurn("Synthetic pending chunk.", scopeID: scope))
        vad(uncertain, "started", item: "uncertain-live"); vad(uncertain, "stopped", item: "uncertain-live")
        asr(uncertain, "A real question", item: "uncertain-live")
        uncertain.injectDiagnosticEvent(["type": "error", "error": ["type": "invalid_request_error", "message": "Response cancel request is invalid."]])
        precondition(uncertaintyErrors.count == 1 && appItems(uncertainEvents).count == 1 && !uncertain.canRequestTurn,
                     "an arbitrary cancel error is not proof of a quiescent server and must pause rather than generate a repair")
        uncertain.stop()
        // ASR-before-created and created-before-ASR both cancel exactly one known reply.
        for asrFirst in [true, false] {
            let ordered = PicoRealtime(); var orderedEvents: [[String: Any]] = []
            ordered.onSentEvent = { orderedEvents.append($0) }
            ordered.onTranscript = { role, _, _ in if role == "other" { ordered.suppressReplyForPresentationResume() } }
            ready(ordered); vad(ordered, "started", item: "resume-order"); vad(ordered, "stopped", item: "resume-order")
            if asrFirst {
                asr(ordered, "继续", item: "resume-order")
                precondition(!ordered.canRequestTurn && !orderedEvents.contains { $0["type"] as? String == "response.cancel" })
            }
            created(ordered, "resume-response")
            if !asrFirst { asr(ordered, "继续", item: "resume-order") }
            ordered.suppressReplyForPresentationResume()
            precondition(orderedEvents.filter { $0["type"] as? String == "response.cancel" }.count == 1 && !ordered.canRequestTurn)
            done(ordered, "resume-response", status: "cancelled")
            precondition(ordered.canRequestTurn)
            ordered.stop(); ordered.onTranscript = nil
        }
        // The provider can finish the resume tool before ASR. No next APP scope may
        // start before the real transcript is handled, and late ASR causes no idle cancel.
        let lateASR = PicoRealtime(); var lateEvents: [[String: Any]] = [], transcriptCount = 0
        lateASR.onSentEvent = { lateEvents.append($0) }; lateASR.presentationControl = { _ in #"{"applied":true}"# }
        lateASR.onTranscript = { role, _, _ in
            if role == "other" {
                transcriptCount += 1
                precondition(!lateASR.canRequestTurn, "the ASR callback itself is still inside this turn's barrier")
                lateASR.suppressReplyForPresentationResume()
            }
        }
        ready(lateASR); vad(lateASR, "started", item: "late-resume"); vad(lateASR, "stopped", item: "late-resume")
        created(lateASR, "resume-tool-first"); done(lateASR, "resume-tool-first", calls: [resume])
        precondition(!lateASR.canRequestTurn && !lateASR.requestSpokenTurn("Must not jump ahead.", scopeID: UUID()))
        asr(lateASR, "不忙，你继续。", item: "late-resume")
        precondition(lateASR.canRequestTurn && !lateEvents.contains { $0["type"] as? String == "response.cancel" })
        let nextScope = UUID(); precondition(lateASR.requestSpokenTurn("The actual next chunk.", scopeID: nextScope))
        asr(lateASR, "不忙，你继续。", item: "late-resume") // Duplicate final after a new request began.
        precondition(transcriptCount == 1 && !lateEvents.contains { $0["type"] as? String == "response.cancel" })
        created(lateASR, "next-scoped-chunk"); precondition(lateASR.scriptScope(for: "next-scoped-chunk") == nextScope)
        done(lateASR, "next-scoped-chunk"); lateASR.onTranscript = nil
        vad(lateASR, "started", item: "fresh-question"); vad(lateASR, "stopped", item: "fresh-question")
        created(lateASR, "fresh-ordinary-answer"); asr(lateASR, "Can I ask about the project?", item: "fresh-question")
        precondition(lateASR.scriptScope(for: "fresh-ordinary-answer") == nil && !lateEvents.contains { $0["type"] as? String == "response.cancel" })
        done(lateASR, "fresh-ordinary-answer"); lateASR.stop()

        let resumedTurn = PicoRealtime(); var sawCompletedResume = false, resumedTranscripts = 0
        resumedTurn.presentationControl = { _ in #"{"applied":true}"# }
        resumedTurn.onTranscript = { role, _, id in
            if role == "other" { resumedTranscripts += 1; sawCompletedResume = resumedTurn.hasCompletedSilentResume(for: id) }
        }
        ready(resumedTurn); vad(resumedTurn, "started", item: "actual-resume-item"); vad(resumedTurn, "stopped", item: "actual-resume-item")
        created(resumedTurn, "model-resume"); done(resumedTurn, "model-resume", calls: [resume])
        precondition(resumedTurn.hasCompletedSilentResume(for: "actual-resume-item") && !resumedTurn.hasCompletedSilentResume(for: "different-item"))
        asr(resumedTurn, "不好，你继续。", item: "actual-resume-item")
        asr(resumedTurn, "不好，你继续。", item: "actual-resume-item")
        precondition(sawCompletedResume && resumedTranscripts == 1, "late ASR reads the completed control for exactly its live audio item, independent of lexical recognition")
        vad(resumedTurn, "started", item: "next-live-item")
        precondition(!resumedTurn.hasCompletedSilentResume(for: "actual-resume-item"), "a new VAD turn invalidates old resume evidence")
        resumedTurn.stop(); precondition(!resumedTurn.hasCompletedSilentResume(for: "actual-resume-item"))
        // ASR may land between applying the tool arguments and its terminal event.
        // Completion notifies once after settling, so the owner can clear a QA wait.
        let betweenEvents = PicoRealtime(); var completedNotices: [String] = [], markerDuringASR = true
        let reconciledScope = UUID()
        betweenEvents.presentationControl = { _ in #"{"applied":true}"# }
        betweenEvents.onTranscript = { role, _, id in if role == "other" { markerDuringASR = betweenEvents.hasCompletedSilentResume(for: id) } }
        betweenEvents.onCompletedSilentResume = { item in
            completedNotices.append(item)
            precondition(betweenEvents.hasCompletedSilentResume(for: item) && betweenEvents.canRequestTurn && !betweenEvents.remoteTurnPending)
            precondition(betweenEvents.requestSpokenTurn("A new scoped turn after reconciliation.", scopeID: reconciledScope), "completion callback can safely schedule after the old transaction is settled")
        }
        ready(betweenEvents); vad(betweenEvents, "started", item: "between-args-and-done"); vad(betweenEvents, "stopped", item: "between-args-and-done")
        created(betweenEvents, "resume-before-final")
        var earlyResume = resume; earlyResume["type"] = "response.function_call_arguments.done"; earlyResume["response_id"] = "resume-before-final"
        betweenEvents.injectDiagnosticEvent(earlyResume)
        asr(betweenEvents, "不好，你继续。", item: "between-args-and-done")
        precondition(!markerDuringASR && completedNotices.isEmpty)
        done(betweenEvents, "resume-before-final", calls: [resume]); done(betweenEvents, "resume-before-final", calls: [resume])
        precondition(completedNotices == ["between-args-and-done"])
        created(betweenEvents, "reconciled-next-scope")
        precondition(betweenEvents.scriptScope(for: "reconciled-next-scope") == reconciledScope, "a callback's new pending request is not overwritten by old cleanup")
        done(betweenEvents, "reconciled-next-scope"); betweenEvents.stop(); betweenEvents.onCompletedSilentResume = nil
        for applied in [false, true] {
            let control = PicoRealtime()
            control.presentationControl = { _ in applied ? #"{"applied":true,"scripted_closing":true}"# : #"{"applied":false}"# }
            ready(control); vad(control, "started", item: "non-resume-item"); vad(control, "stopped", item: "non-resume-item")
            created(control, "non-resume-control")
            let item = applied ? ["type": "function_call", "name": "control_presentation", "call_id": "conclude-control", "arguments": #"{"action":"conclude"}"#] : resume
            done(control, "non-resume-control", calls: [item])
            precondition(!control.hasCompletedSilentResume(for: "non-resume-item"), "a declined resume or scripted closing is not silent-resume evidence")
            control.stop()
        }
        let mixedResume = PicoRealtime(); var mixedResumeEvents: [[String: Any]] = [], mixedNotices = 0
        mixedResume.onSentEvent = { mixedResumeEvents.append($0) }
        mixedResume.onCompletedSilentResume = { _ in mixedNotices += 1 }
        mixedResume.presentationControl = { _ in #"{"applied":true}"# }
        mixedResume.memoryLookup = { _ in await Task.yield(); return PicoMemoryResult(notes: []) }
        ready(mixedResume); vad(mixedResume, "started", item: "question-and-resume"); vad(mixedResume, "stopped", item: "question-and-resume")
        created(mixedResume, "mixed-question-control")
        let memory: [String: Any] = ["type": "function_call", "name": "telos_memory_search", "call_id": "mixed-resume-memory", "arguments": #"{"query":"synthetic project"}"#]
        done(mixedResume, "mixed-question-control", calls: [memory, resume])
        for _ in 0..<100 where !mixedResumeEvents.contains(where: { $0["type"] as? String == "response.create" }) { await Task.yield() }
        precondition(mixedResumeEvents.contains { $0["type"] as? String == "response.create" } && !mixedResume.hasCompletedSilentResume(for: "question-and-resume"),
                     "a substantive memory question must retain its normal spoken-answer wait")
        created(mixedResume, "mixed-followup")
        let followupResume: [String: Any] = ["type": "function_call", "name": "control_presentation", "call_id": "mixed-later-resume", "arguments": #"{"action":"resume"}"#]
        done(mixedResume, "mixed-followup", calls: [followupResume])
        precondition(!mixedResume.hasCompletedSilentResume(for: "question-and-resume") && mixedNotices == 0, "a later pure resume cannot erase a substantive tool earlier in the same live turn")
        mixedResume.stop()
        let quoted = PicoRealtime(); quoted.presentationControl = { _ in #"{"applied":true}"# }
        ready(quoted); vad(quoted, "started", item: "previous-live"); vad(quoted, "stopped", item: "previous-live")
        asr(quoted, "A real completed question", item: "previous-live"); created(quoted, "previous-answer"); done(quoted, "previous-answer")
        precondition(quoted.requestSpokenTurn("Quoted reference says resume, but it is not a fresh live command.", scopeID: UUID()))
        created(quoted, "quoted-script"); done(quoted, "quoted-script", calls: [resume])
        precondition(!quoted.hasCompletedSilentResume(for: "previous-live"), "an app-scoped or quoted command cannot masquerade as completed control for an old live utterance")
        quoted.stop()

        let invalidTurn = PicoRealtime(); var invalidTranscripts = 0
        invalidTurn.onTranscript = { _, _, _ in invalidTranscripts += 1 }
        ready(invalidTurn); vad(invalidTurn, "started", item: "filtered-audio")
        invalidTurn.injectDiagnosticEvent(["type": "input_audio_buffer.speech_stopped", "item_id": "filtered-audio", "reason": "turn_invalid"])
        precondition(invalidTurn.canRequestTurn, "smart-turn rejection does not wait for ASR that will never be sent")
        asr(invalidTurn, "A delayed rejected fragment", item: "filtered-audio")
        precondition(invalidTranscripts == 0); invalidTurn.stop()

        // A cancel can reach the provider after its response already completed. Its
        // later exact error consumes only the old ticket, never a new scoped request.
        let oldCancel = PicoRealtime(); var cancelErrors: [String] = [], cancelAudio: [String] = []
        oldCancel.onError = { cancelErrors.append($0) }; oldCancel.onAudio = { _, id in cancelAudio.append(id) }
        ready(oldCancel); created(oldCancel, "just-completed"); oldCancel.suppressReplyForPresentationResume()
        done(oldCancel, "just-completed")
        let freshScope = UUID(); precondition(oldCancel.requestSpokenTurn("A new scoped chunk.", scopeID: freshScope))
        created(oldCancel, "new-app-after-cancel")
        oldCancel.injectDiagnosticEvent(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_value", "param": "response.cancel", "message": "Conversation has no active response."]])
        audio(oldCancel, "new-app-after-cancel")
        precondition(cancelErrors.isEmpty && cancelAudio == ["new-app-after-cancel"] && oldCancel.scriptScope(for: "new-app-after-cancel") == freshScope)
        done(oldCancel, "new-app-after-cancel"); oldCancel.stop()
        for wrongParam in [false, true] {
            let rejected = PicoRealtime(); var failures: [String] = []
            rejected.onError = { failures.append($0) }; ready(rejected)
            if wrongParam { created(rejected, "known-cancel"); rejected.suppressReplyForPresentationResume() }
            rejected.injectDiagnosticEvent(["type": "error", "error": ["type": "invalid_request_error", "code": "invalid_value", "param": wrongParam ? "response.create" : "response.cancel", "message": "Conversation has no active response."]])
            precondition(failures.count == 1 && !rejected.canRequestTurn, "wrong param or no actual sent cancellation must not swallow invalid_value")
            rejected.stop()
        }
        await PicoRealtime.verifyScopedRepairTimeout()
        print("PASS: temporary app items deleted once, local-only script scopes, late-ASR ordinary QA, VAD in-flight cancellation/one-shot answer repair, tool follow-up scopes, resume suppression, timeout pause, stale audio rejection and stop cleanup. No network, UI, keys or speech.")
    }
}

#if PICO_SCOPED_SPEECH_STANDALONE
@main struct PicoScopedSpeechStandaloneTests {
    @MainActor static func main() async { await PicoScopedSpeechTests.run() }
}
#endif
