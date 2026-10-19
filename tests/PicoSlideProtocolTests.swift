import Foundation

@MainActor private final class SlideProtocolNavigation {
    var pages: [Int] = []
    private var completions: [CheckedContinuation<String, Never>] = []
    func navigate(_ page: Int) async -> String {
        pages.append(page)
        return await withCheckedContinuation { completions.append($0) }
    }
    func finish(_ output: String = #"{"displayed":true}"#) {
        precondition(!completions.isEmpty)
        completions.removeFirst().resume(returning: output)
    }
}

enum PicoSlideProtocolTests {
    @MainActor private static func wait(_ condition: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Synthetic slide protocol timed out")
            await Task.yield()
        }
    }
    private static func call(_ callID: String, responseID: String, arguments: String) -> [String: Any] {
        ["type": "response.function_call_arguments.done", "name": "show_slide", "call_id": callID,
         "response_id": responseID, "arguments": arguments]
    }
    private static func done(_ responseID: String, calls: [[String: Any]], status: String = "completed") -> [String: Any] {
        ["type": "response.done", "response": ["id": responseID, "status": status,
            "output": calls.map { event in var event = event; event["type"] = "function_call"; return event }]]
    }
    private static func outputs(_ sent: [[String: Any]]) -> [[String: Any]] {
        sent.filter { $0["type"] as? String == "conversation.item.create" }
            .compactMap { $0["item"] as? [String: Any] }
            .filter { $0["type"] as? String == "function_call_output" }
    }
    @MainActor static func run() async {
        let noSlides = PicoMeetingPrompt.session(brief: "synthetic", history: "", slides: false)["session"] as! [String: Any]
        precondition((noSlides["tools"] as! [[String: Any]]).isEmpty)
        let withSlides = PicoMeetingPrompt.session(brief: "synthetic", history: "", slides: true)["session"] as! [String: Any]
        let tool = (withSlides["tools"] as! [[String: Any]])[0]["function"] as! [String: Any]
        precondition(tool["name"] as? String == "show_slide")
        let parameters = tool["parameters"] as! [String: Any]
        precondition(parameters["required"] as? [String] == ["page"] && parameters["additionalProperties"] as? Bool == false)
        let page = (parameters["properties"] as! [String: Any])["page"] as! [String: Any]
        precondition(page["type"] as? String == "integer" && page["minimum"] as? Int == 1 && page["maximum"] as? Int == 60)

        for (index, argument) in [#"{"page":1}"#, #"{"page":60}"#, #"{"page":3.0}"#].enumerated() {
            let client = PicoRealtime(), nav = SlideProtocolNavigation()
            var sent: [[String: Any]] = []
            client.slideNavigation = { await nav.navigate($0) }; client.onSentEvent = { sent.append($0) }
            client.injectDiagnosticEvent(["type": "session.updated"])
            let response = "valid-\(index)", event = call("call-\(index)", responseID: response, arguments: argument)
            client.injectDiagnosticEvent(["type": "response.created", "response": ["id": response]])
            client.injectDiagnosticEvent(event); client.injectDiagnosticEvent(event)
            await wait { nav.pages.count == 1 }
            precondition(nav.pages == [[1, 60, 3][index]])
            nav.finish()
            for _ in 0..<10 { await Task.yield() }
            precondition(outputs(sent).isEmpty, "the async navigation result must wait for its model turn to end")
            client.injectDiagnosticEvent(done(response, calls: [event]))
            await wait { outputs(sent).count == 1 }
            client.injectDiagnosticEvent(done(response, calls: [event]))
            precondition(nav.pages.count == 1 && outputs(sent).count == 1)
            precondition(sent.filter { $0["type"] as? String == "response.create" }.count == 1)
            client.stop()
        }

        let invalid = [#"{"page":true}"#, #"{"page":false}"#, #"{"page":"3"}"#, #"{"page":3.5}"#,
                       #"{"page":0}"#, #"{"page":-1}"#, #"{"page":61}"#, #"{"page":null}"#, #"{"page":[]}"#,
                       #"{"page":{},"url":"https://example.invalid"}"#, #"{"page":3,"url":"https://example.invalid"}"#,
                       #"{}"#, #"[]"#, #"not json"#, String(repeating: "x", count: 4097)]
        for (index, argument) in invalid.enumerated() {
            let client = PicoRealtime(), nav = SlideProtocolNavigation()
            var sent: [[String: Any]] = []
            client.slideNavigation = { await nav.navigate($0) }; client.onSentEvent = { sent.append($0) }
            client.injectDiagnosticEvent(["type": "session.updated"])
            let response = "invalid-\(index)", event = call("bad-\(index)", responseID: response, arguments: argument)
            client.injectDiagnosticEvent(["type": "response.created", "response": ["id": response]])
            client.injectDiagnosticEvent(event); client.injectDiagnosticEvent(done(response, calls: [event]))
            await wait { outputs(sent).count == 1 }
            precondition(nav.pages.isEmpty && (outputs(sent)[0]["output"] as? String)?.contains("error") == true,
                         "invalid tool arguments must not invoke any navigation")
            client.stop()
        }

        // A provider may deliver the function only in a completed response.done event.
        let fallback = PicoRealtime(), fallbackNav = SlideProtocolNavigation()
        var fallbackSent: [[String: Any]] = []
        fallback.slideNavigation = { await fallbackNav.navigate($0) }; fallback.onSentEvent = { fallbackSent.append($0) }
        fallback.injectDiagnosticEvent(["type": "session.updated"])
        fallback.injectDiagnosticEvent(["type": "response.created", "response": ["id": "fallback"]])
        let fallbackCall = call("fallback-call", responseID: "fallback", arguments: #"{"page":2}"#)
        fallback.injectDiagnosticEvent(done("fallback", calls: [fallbackCall]))
        await wait { fallbackNav.pages == [2] }
        fallbackNav.finish(String(repeating: "x", count: 4097))
        await wait { outputs(fallbackSent).count == 1 }
        precondition((outputs(fallbackSent)[0]["output"] as? String)?.contains("exceeded") == true)
        precondition((outputs(fallbackSent)[0]["output"] as? String)?.utf8.count ?? 9999 < 4096)
        fallback.stop()

        // Canceled or failed terminal turns are not new authority to perform an action.
        for status in ["cancelled", "failed"] {
            let client = PicoRealtime(), nav = SlideProtocolNavigation()
            var sent: [[String: Any]] = []
            client.slideNavigation = { await nav.navigate($0) }; client.onSentEvent = { sent.append($0) }
            client.injectDiagnosticEvent(["type": "session.updated"])
            client.injectDiagnosticEvent(["type": "response.created", "response": ["id": status]])
            client.injectDiagnosticEvent(done(status, calls: [call(status + "-call", responseID: status, arguments: #"{"page":2}"#)], status: status))
            for _ in 0..<20 { await Task.yield() }
            precondition(nav.pages.isEmpty && outputs(sent).isEmpty,
                         "canceled/failed turn output must not trigger slide navigation")
            client.stop()
        }

        for stopping in [false, true] {
            let client = PicoRealtime(), nav = SlideProtocolNavigation()
            var sent: [[String: Any]] = []
            client.slideNavigation = { await nav.navigate($0) }; client.onSentEvent = { sent.append($0) }
            client.injectDiagnosticEvent(["type": "session.updated"])
            client.injectDiagnosticEvent(["type": "response.created", "response": ["id": "late"]])
            let event = call("late-call", responseID: "late", arguments: #"{"page":4}"#)
            client.injectDiagnosticEvent(event)
            await wait { nav.pages == [4] }
            if stopping { client.stop(); client.injectDiagnosticEvent(["type": "session.updated"]) }
            else { client.injectDiagnosticEvent(["type": "input_audio_buffer.speech_started"]) }
            client.injectDiagnosticEvent(event) // Duplicate and now stale.
            nav.finish()
            client.injectDiagnosticEvent(done("late", calls: [event]))
            for _ in 0..<20 { await Task.yield() }
            precondition(nav.pages == [4] && outputs(sent).isEmpty,
                         "interruption/stop/renewal must discard the late async result and never navigate twice")
            client.stop()
        }
        let unavailable = PicoRealtime()
        var unavailableSent: [[String: Any]] = []
        unavailable.onSentEvent = { unavailableSent.append($0) }
        unavailable.injectDiagnosticEvent(["type": "session.updated"])
        unavailable.injectDiagnosticEvent(["type": "response.created", "response": ["id": "unavailable"]])
        let missing = call("missing-navigation", responseID: "unavailable", arguments: #"{"page":1}"#)
        unavailable.injectDiagnosticEvent(missing); unavailable.injectDiagnosticEvent(done("unavailable", calls: [missing]))
        precondition(outputs(unavailableSent).count == 1 && (outputs(unavailableSent)[0]["output"] as? String)?.contains("unavailable") == true)
        unavailable.stop()
        let scriptPrompt = PicoMeetingPrompt.instructions(brief: "synthetic", history: "", presentationControl: true, slides: true)
        precondition(scriptPrompt.contains("prepared opening faithfully") && !scriptPrompt.contains("Explain briefly that the conversation is transcribed"))
        precondition(scriptPrompt.contains("polite request") || scriptPrompt.contains("polite request".capitalized))
        let closingClient = PicoRealtime()
        var closingEvents: [[String: Any]] = []
        closingClient.onSentEvent = { closingEvents.append($0) }
        closingClient.presentationControl = { _ in #"{"applied":true,"scripted_closing":true}"# }
        closingClient.injectDiagnosticEvent(["type": "session.updated"])
        closingClient.injectDiagnosticEvent(["type": "response.created", "response": ["id": "closing-control"]])
        let closingCall: [String: Any] = ["type": "response.function_call_arguments.done", "name": "control_presentation", "call_id": "closing-call", "response_id": "closing-control", "arguments": #"{"action":"conclude"}"#]
        closingClient.injectDiagnosticEvent(closingCall)
        closingClient.injectDiagnosticEvent(done("closing-control", calls: [closingCall]))
        precondition(outputs(closingEvents).count == 1 && !closingEvents.contains { $0["type"] as? String == "response.create" }, "the app-owned closing must not get a second model-generated conclusion")
        precondition(closingClient.canRequestTurn)
        closingClient.stop()
        print("PASS: show_slide schema, numeric bounds/Bool rejection, malformed and extra arguments, duplicate IDs, terminal fallback, oversized results, unavailable tool, cancellation and late async-result fences. No UI, network, key access or speech.")
    }
}

#if PICO_SLIDE_PROTOCOL_STANDALONE
@main struct PicoSlideProtocolStandaloneTests {
    @MainActor static func main() async { await PicoSlideProtocolTests.run() }
}
#endif
