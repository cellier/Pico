import Foundation

@MainActor enum PicoRealtimeLanguageTests {
    private static func event(_ client: PicoRealtime, _ type: String, _ values: [String: Any] = [:]) {
        var payload = values; payload["type"] = type; client.injectDiagnosticEvent(payload)
    }
    private static func ready(_ client: PicoRealtime) { event(client, "session.updated") }
    private static func vad(_ client: PicoRealtime, _ type: String, item: String) {
        event(client, "input_audio_buffer.speech_" + type, ["item_id": item])
    }
    private static func asr(_ client: PicoRealtime, _ text: String, item: String) {
        event(client, "conversation.item.input_audio_transcription.completed", ["item_id": item, "transcript": text])
    }
    private static func created(_ client: PicoRealtime, _ id: String) {
        event(client, "response.created", ["response": ["id": id]])
    }
    private static func done(_ client: PicoRealtime, _ id: String, status: String = "completed") {
        event(client, "response.done", ["response": ["id": id, "status": status]])
    }
    private static func appTexts(_ events: [[String: Any]]) -> [String] {
        events.filter { $0["type"] as? String == "conversation.item.create" }
            .compactMap { $0["item"] as? [String: Any] }
            .filter { ($0["id"] as? String)?.hasPrefix("pico_app_") == true }
            .compactMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
    }
    static func run() {
        var initialLanguage = PicoMeetingLanguage(defaultLanguage: "zh-CN")
        let automaticSession = PicoMeetingPrompt.session(brief: "Synthetic", history: "", meetingLanguage: initialLanguage)["session"] as! [String: Any]
        precondition(automaticSession["output_audio"] == nil, "without an explicit choice, TTS must remain free to follow live guest language")
        precondition(initialLanguage.consume("Can you switch to Japanese?", audioItemID: "initial-choice"))
        let selectedSession = PicoMeetingPrompt.session(brief: "Synthetic", history: "", meetingLanguage: initialLanguage)["session"] as! [String: Any]
        precondition((selectedSession["output_audio"] as! [String: String])["language"] == "ja", "a new or reconnected explicit-language session must restore its matching TTS language")
        let client = PicoRealtime(); var sent: [[String: Any]] = [], order: [String] = []
        var readyCount = 0, languageChanges: [String] = [], played: [String] = [], scopes: [UUID?] = []
        client.onSentEvent = { sent.append($0) }; client.onReady = { readyCount += 1 }
        client.onInterruption = { order.append("interrupt") }
        client.onTranscript = { role, _, _ in if role == "other" { order.append("transcript") } }
        client.onMeetingLanguageChanged = { languageChanges.append($0) }
        client.onAudio = { _, id in played.append(id) }
        client.onResponseStarted = { scopes.append(client.scriptScope(for: $0)) }
        ready(client)
        vad(client, "started", item: "english"); vad(client, "stopped", item: "english")
        created(client, "old-chinese-reply")
        order.removeAll()
        asr(client, "Please speak English from now on.", item: "english")
        precondition(client.meetingLanguage.language.hasPrefix("en") && client.meetingLanguage.isExplicitlySelected)
        precondition(order == ["interrupt", "transcript"], "old queued audio must be cleared before the controller establishes the new guest wait")
        let updates = sent.filter { $0["type"] as? String == "session.update" }
        let update = updates.last!["session"] as! [String: Any]
        precondition(Set(update.keys) == Set(["instructions", "output_audio"]), "a live session update must not change VAD, tools or the incoming ASR language")
        precondition((update["output_audio"] as! [String: String])["language"] == "en")
        precondition((update["instructions"] as! String).contains(client.meetingLanguage.sessionInstruction))
        precondition(sent.filter { $0["type"] as? String == "response.cancel" }.count == 1)
        event(client, "response.audio.delta", ["response_id": "old-chinese-reply", "delta": Data([0, 1]).base64EncodedString()])
        done(client, "old-chinese-reply", status: "cancelled")
        precondition(appTexts(sent).isEmpty && played.isEmpty, "late old-language audio is rejected and repair must wait for language ACK")
        ready(client)
        precondition(readyCount == 1, "a dynamic language ACK must not restart the script via onReady")
        precondition(appTexts(sent).count == 1 && appTexts(sent)[0].contains("APP-RECOVERED LIVE CONVERSATION TURN"))
        created(client, "english-repair")
        precondition(scopes.last! == nil, "language recovery is ordinary conversation, never a prepared script scope")
        done(client, "english-repair")
        precondition(client.canRequestTurn)
        let scope = UUID()
        precondition(client.requestSpokenTurn("APP-SCHEDULED SCRIPT TURN. 中文源文。", scopeID: scope, sourceLanguage: "zh-CN"))
        precondition(appTexts(sent).last!.contains(client.meetingLanguage.speechInstruction(sourceLanguage: "zh-CN")))
        created(client, "english-script"); done(client, "english-script")

        // Speaking Chinese is not an instruction to switch back. Old ASR cannot
        // overwrite the current participant's explicit preference either.
        vad(client, "started", item: "ordinary-chinese"); vad(client, "stopped", item: "ordinary-chinese")
        let revision = client.meetingLanguage.revision
        asr(client, "这个演示有几页？", item: "ordinary-chinese")
        precondition(client.meetingLanguage.revision == revision && client.meetingLanguage.language.hasPrefix("en"))
        asr(client, "现在请切回中文。", item: "stale-other-audio")
        precondition(client.meetingLanguage.revision == revision)
        created(client, "ordinary-answer"); done(client, "ordinary-answer")
        client.stop()
        precondition(client.meetingLanguage.language.hasPrefix("en"), "stopping for takeover/recovery must retain the current meeting preference")
        ready(client)
        precondition(client.requestSpokenTurn("合成重连段。", sourceLanguage: "zh-CN"))
        precondition(appTexts(sent).last!.contains(client.meetingLanguage.speechInstruction(sourceLanguage: "zh-CN")))
        created(client, "after-reconnect"); done(client, "after-reconnect")
        client.resetMeetingLanguage(defaultLanguage: "zh-CN")
        precondition(client.meetingLanguage.language.hasPrefix("zh") && !client.meetingLanguage.isExplicitlySelected)
        client.stop()

        // ASR first: fence the not-yet-created old automatic response; do not issue
        // a response.cancel until a real server response ID exists.
        let early = PicoRealtime(); var earlySent: [[String: Any]] = []
        early.onSentEvent = { earlySent.append($0) }; ready(early)
        vad(early, "started", item: "japanese"); vad(early, "stopped", item: "japanese")
        asr(early, "接下来请一直用日语介绍。", item: "japanese")
        precondition(early.meetingLanguage.language.hasPrefix("ja") && !early.canRequestTurn)
        precondition(!earlySent.contains { $0["type"] as? String == "response.cancel" })
        ready(early); precondition(appTexts(earlySent).isEmpty)
        created(early, "automatic-before-update")
        precondition(earlySent.filter { $0["type"] as? String == "response.cancel" }.count == 1)
        done(early, "automatic-before-update", status: "cancelled")
        precondition(appTexts(earlySent).count == 1)
        created(early, "japanese-repair"); done(early, "japanese-repair")
        precondition(early.canRequestTurn)
        early.stop()

        // Provider generation can finish before ASR. Its still-queued old audio
        // is cleared, but a finished response must never receive response.cancel.
        let late = PicoRealtime(); var lateSent: [[String: Any]] = [], lateInterruptions = 0
        late.onSentEvent = { lateSent.append($0) }; late.onInterruption = { lateInterruptions += 1 }
        ready(late); vad(late, "started", item: "late-language"); vad(late, "stopped", item: "late-language")
        created(late, "already-finished"); done(late, "already-finished")
        let beforeLateASR = lateInterruptions
        asr(late, "现在请切换到日语。", item: "late-language")
        precondition(lateInterruptions == beforeLateASR + 1)
        precondition(!lateSent.contains { $0["type"] as? String == "response.cancel" })
        ready(late)
        precondition(appTexts(lateSent).count == 1)
        created(late, "fresh-late-language"); done(late, "fresh-late-language")
        precondition(late.canRequestTurn && late.meetingLanguage.language.hasPrefix("ja"))
        late.stop()
        print("PASS: production meeting-language state, dynamic instructions and TTS field, ASR-first/late cancellation barriers, stale audio rejection, reconnect and explicit-only reset")
    }
}
