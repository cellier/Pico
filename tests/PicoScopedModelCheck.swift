import Foundation
import AVFoundation

/// Explicit opt-in integration check. Uses synthetic files, no microphone, Zoom,
/// owner memories, playback or credential output. Uses the app's saved account normally.
@MainActor enum PicoScopedModelCheck {
    static func run(directory: URL) async throws {
        let realtime = PicoRealtime()
        var ready = false, failure: String?, terminalCount = 0, commits = 0, stops = 0, deletions = 0, continuationControls = 0
        var providerErrors: [[String: Any]] = []
        var phase = "connect", events: [String] = [], toolActions: [String] = [], cancelCount = 0
        var ordered: [String] = [], texts: [String: String] = [:], audio: [String: Int] = [:], scopes: [String: UUID] = [:]
        var results: [[String: Any]] = []
        var latestGuest: (id: String, text: String)?
        var meetingFinishBindings: [[String: Any]] = [], meetingFinishApplications = 0, meetingFinishOutputs = 0
        let first = "你好，我是虚构的演示助手。今天介绍的项目代号是青柏。"
        let second = "青柏帮助学生按主题整理读书笔记，方便日后查找。"
        let script = PicoPresentationScript(deckURL: "https://slides.zoom.us/p/synthetic/10000", title: "Synthetic",
            opening: [.init(text: first)], slides: [.init(number: 1, title: "Synthetic", chunks: [.init(text: second)])])
        var preparation = PicoMeetingPreparation(); preparation.present = true; preparation.presentationScript = script
        realtime.preparationContext = preparation.context
        realtime.slideNavigation = { _ in #"{"ok":false,"message":"Synthetic test has no real meeting or slideshow."}"# }
        realtime.presentationControl = { action in
            toolActions.append(action)
            events.append("tool_" + action)
            return #"{"applied":true,"scripted_closing":true,"action":"\#(action)"}"#
        }
        // Mirrors the controller's intent gate without binding or operating any meeting.
        // The realtime layer must deliver this same audio item's ASR callback first.
        realtime.meetingFinish = { audioItemID in
            let sameItem = latestGuest?.id == audioItemID
            let explicitGoodbye = latestGuest.map { PicoMeetingController.isMeetingGoodbye($0.text) } ?? false
            let applied = sameItem && explicitGoodbye && meetingFinishApplications == 0
            meetingFinishBindings.append(["audioItemID": audioItemID, "sameAudioTranscript": sameItem,
                                          "explicitLiveGoodbye": explicitGoodbye, "applied": applied])
            events.append("finish_gate_\(applied ? "applied" : "declined")_item=" + audioItemID)
            if applied { meetingFinishApplications += 1 }
            return applied ? #"{"applied":true,"farewell_pending":true,"scope":"synthetic_no_exit"}"# :
                #"{"applied":false,"reason":"No matching explicit synthetic live goodbye."}"#
        }
        realtime.onReady = { ready = true }
        realtime.onError = { failure = $0 }; realtime.onRecoverableError = { failure = $0 }
        realtime.onProviderError = { error in
            providerErrors.append(error)
            print("SYNTHETIC_PROVIDER_ERROR: " + String(describing: error))
        }
        realtime.onResponseStarted = { id in
            ordered.append(id)
            if let scope = realtime.scriptScope(for: id) { scopes[id] = scope }
        }
        realtime.onAudio = { bytes, id in audio[id, default: 0] += bytes.count }
        realtime.onTranscript = { role, text, id in
            if role == "pico" { texts[id] = text }
            if role == "other" {
                latestGuest = (id, text)
                if PicoMeetingController.isMeetingGoodbye(text) { events.append("asr_goodbye_item=" + id) }
            }
            if role == "other", PicoMeetingController.isSimpleContinuation(text) || realtime.hasCompletedSilentResume(for: id) {
                if realtime.hasCompletedSilentResume(for: id) { events.append("same_audio_silent_resume_confirmed") }
                events.append("asr_continue")
                continuationControls += 1
                realtime.suppressReplyForPresentationResume()
            }
        }
        realtime.onSentEvent = { event in
            let type = event["type"] as? String ?? "unknown"
            if type == "response.cancel" { cancelCount += 1 }
            if type == "response.cancel" || type == "response.create" { events.append("sent_" + type) }
            if type == "conversation.item.create", let item = event["item"] as? [String: Any],
               item["type"] as? String == "function_call_output", let output = item["output"] as? String,
               let bytes = output.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               value["applied"] as? Bool == true, value["farewell_pending"] as? Bool == true {
                meetingFinishOutputs += 1; events.append("finish_tool_output_applied")
            }
        }
        realtime.onDiagnosticEvent = { event in
            if !event.contains("delta") { events.append(event) }
            if event.hasPrefix("response.done ") { terminalCount += 1 }
            if event.hasPrefix("input_audio_buffer.committed ") { commits += 1 }
            if event.hasPrefix("input_audio_buffer.speech_stopped ") { stops += 1 }
            if event.hasPrefix("conversation.item.deleted ") { deletions += 1 }
        }
        func wait(_ predicate: () -> Bool, seconds: TimeInterval = 40, silence: Bool = false) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !predicate(), failure == nil, Date() < deadline {
                if silence { realtime.append(Data(count: 3200)) }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            if let failure { throw NSError(domain: "PicoScopedModelCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: failure]) }
            guard predicate() else { throw NSError(domain: "PicoScopedModelCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for the controlled response."]) }
        }
        func request(_ text: String, scope: UUID, kind: String = "scheduled") async throws {
            phase = "scheduled_\(results.count)"
            try await wait({ realtime.canRequestTurn })
            let before = terminalCount, oldDeletions = deletions, offset = ordered.count
            let instruction = kind == "farewell" ?
                "APP-SCHEDULED MEETING FAREWELL. The synthetic participant explicitly ended the conversation. Speak only this approved goodbye once, with no tools, additions or claims of leaving: " :
                "APP-SCHEDULED SCRIPT TURN. Speak only this approved line once, with no additions: "
            guard realtime.requestSpokenTurn(instruction + text, scopeID: scope) else { throw URLError(.cannotLoadFromNetwork) }
            try await wait({ terminalCount > before && realtime.canRequestTurn })
            try await wait({ deletions > oldDeletions }, seconds: 10)
            let ids = Array(ordered.dropFirst(offset))
            let spoken = ids.filter { audio[$0, default: 0] > 0 }
            guard spoken.count == 1, scopes[spoken[0]] == scope, !(texts[spoken[0]] ?? "").isEmpty else { throw NSError(domain: "PicoScopedModelCheck", code: 3, userInfo: [NSLocalizedDescriptionKey: "Scheduled speech lost scope, repeated, or produced no audio."]) }
            results.append(["kind": kind, "text": texts[spoken[0]] ?? "", "audioBytes": audio[spoken[0]] ?? 0, "scopeMatched": true, "temporaryPromptDeleted": true])
        }
        func guest(_ fixture: String, forbidScript: Bool) async throws {
            phase = "guest_" + fixture
            let eventOffset = events.count, oldCancels = cancelCount
            let oldContinuationControls = continuationControls
            let offset = ordered.count, before = terminalCount, oldCommits = commits, oldStops = stops
            let file = try AVAudioFile(forReading: directory.appendingPathComponent("scoped-speech-fixtures/" + fixture + ".aiff"))
            let converter = MeetingPCMConverter()
            while file.framePosition < file.length {
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
                try file.read(into: buffer, frameCount: 1600)
                realtime.append(try converter.convert(buffer))
                try await Task.sleep(nanoseconds: UInt64(Double(buffer.frameLength) / file.processingFormat.sampleRate * 1_000_000_000))
            }
            let waitingSince = Date()
            try await wait({
                let completed = commits > oldCommits && terminalCount > before && realtime.canRequestTurn
                // Smart-turn may correctly decline an incomplete/continuation backchannel.
                let filtered = forbidScript && stops > oldStops && realtime.canRequestTurn && Date().timeIntervalSince(waitingSince) >= 8
                return completed || filtered
            }, silence: true)
            let ids = Array(ordered.dropFirst(offset)), reply = ids.compactMap { texts[$0] }.joined(separator: "\n")
            if fixture == "continue", continuationControls != oldContinuationControls + 1 {
                throw NSError(domain: "PicoScopedModelCheck", code: 8, userInfo: [NSLocalizedDescriptionKey: "Continuation audio did not exercise exactly one ASR suppression; it cannot count as a pass."])
            }
            guard ids.allSatisfy({ scopes[$0] == nil }) else { throw NSError(domain: "PicoScopedModelCheck", code: 4, userInfo: [NSLocalizedDescriptionKey: "A live reply inherited a script scope."]) }
            let normalized: (String) -> String = { $0.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined() }
            if forbidScript {
                guard !normalized(reply).contains(normalized(first)), !normalized(reply).contains(normalized(second)) else { throw NSError(domain: "PicoScopedModelCheck", code: 5, userInfo: [NSLocalizedDescriptionKey: "A short live utterance replayed scheduled script content."]) }
            }
            results.append(["kind": "live_synthetic_audio", "fixture": fixture, "reply": reply, "ordinaryScope": true, "filteredBackchannel": ids.isEmpty, "audioBytes": ids.reduce(0) { $0 + audio[$1, default: 0] }, "observedEventOrder": Array(events.dropFirst(eventOffset)), "cancellations": cancelCount - oldCancels])
        }
        do {
            realtime.start(brief: "This is a controlled synthetic presentation test. Speak Chinese. Do not introduce yourself outside the exact app-scheduled line. On a real question answer only that question. An incomplete utterance needs a short clarification, never replay or progress the prepared script. Simple continue requests may use the presentation tool; the app alone reads the next line. When the live synthetic participant explicitly says 今天就先到这吧，拜拜, call finish_meeting and wait silently for the app's one farewell. This check never actually exits or controls Zoom.", history: "")
            try await wait({ ready }, seconds: 25)
            phase = "idle_resume_is_idempotent"
            realtime.suppressReplyForPresentationResume()
            realtime.suppressReplyForPresentationResume()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard failure == nil, providerErrors.isEmpty, cancelCount == 0, realtime.canRequestTurn else {
                throw NSError(domain: "PicoScopedModelCheck", code: 7, userInfo: [NSLocalizedDescriptionKey: "Idle resume must not send an invalid cancellation or lock the next turn."])
            }
            try await request(first, scope: UUID())
            try await guest("continue", forbidScript: true)
            try await request(second, scope: UUID())
            try await guest("continue", forbidScript: true)
            try await request("这部分就介绍到这里，接下来可以聊聊你的想法。", scope: UUID())
            try await guest("question", forbidScript: false)
            guard continuationControls == 2 else { throw NSError(domain: "PicoScopedModelCheck", code: 6, userInfo: [NSLocalizedDescriptionKey: "Both continuation utterances must reach the production ASR suppression path."]) }
            phase = "meeting_finish_same_audio_asr"
            let finishEventOffset = events.count
            try await guest("goodbye", forbidScript: false)
            guard meetingFinishApplications == 1, meetingFinishBindings.count == 1, meetingFinishOutputs == 1 else {
                throw NSError(domain: "PicoScopedModelCheck", code: 10, userInfo: [NSLocalizedDescriptionKey: "The finish tool must apply exactly once after its own live goodbye transcript, not an older or different audio item."])
            }
            let farewellScope = UUID()
            try await request("好，那今天就先到这里。谢谢你的时间，拜拜。", scope: farewellScope, kind: "farewell")
            results.append(["kind": "meeting_finish", "sameAudioASRGate": meetingFinishBindings,
                            "appliedToolOutputs": meetingFinishOutputs, "oneAppScopedFarewell": true,
                            "observedEventOrder": Array(events.dropFirst(finishEventOffset)), "actuallyLeftMeeting": false])
            guard providerErrors.allSatisfy({ $0["type"] as? String == "invalid_request_error" && $0["code"] as? String == "invalid_value" && $0["param"] as? String == "response.cancel" && $0["message"] as? String == "Conversation has no active response." }) else {
                throw NSError(domain: "PicoScopedModelCheck", code: 9, userInfo: [NSLocalizedDescriptionKey: "An unexpected provider error must not count as a successful check."])
            }
            let report: [String: Any] = ["passed": true, "results": results, "temporaryPromptDeletionAcks": deletions, "continuationControls": continuationControls, "toolActions": toolActions, "providerErrors": providerErrors, "handledCancellationRaces": providerErrors.count, "meetingFinishBindings": meetingFinishBindings, "noMicrophoneOrMeetingPlayback": true, "noZoomExit": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("scoped-model-check.json"))
            realtime.stop()
            print("PASS: real Bailian scoped speech, temporary prompt deletion, two live continuations without script replay, ordinary Q&A, same-audio goodbye ASR gate and one scoped farewell; no microphone, Zoom playback or exit")
        } catch {
            realtime.stop()
            let report: [String: Any] = ["passed": false, "phase": phase, "events": events, "error": error.localizedDescription, "results": results, "continuationControls": continuationControls, "providerErrors": providerErrors, "meetingFinishBindings": meetingFinishBindings, "noMicrophoneOrMeetingPlayback": true, "noZoomExit": true]
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("scoped-model-check.json"))
            throw error
        }
    }
}
