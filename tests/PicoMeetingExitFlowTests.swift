import Foundation

enum PicoMeetingExitFlowTests {
    static func run() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000), epoch = UUID()
        var flow = PicoMeetingExitFlow()
        precondition(!flow.pending && !flow.freezesScript && !flow.cancel(), "an ordinary idle interruption must not poison a later exit request")
        precondition(flow.request(epoch: epoch, now: now) && flow.pending && flow.freezesScript)
        precondition(!flow.request(epoch: UUID(), now: now), "duplicate exit requests cannot replace the original epoch/deadline")
        precondition(!flow.responseStarted(id: "too-early", epoch: epoch))
        precondition(!flow.markSpeechRequested(epoch: UUID()))
        precondition(flow.markSpeechRequested(epoch: epoch) && !flow.markSpeechRequested(epoch: epoch))
        precondition(!flow.responseStarted(id: "stale", epoch: UUID()))
        precondition(flow.responseStarted(id: "farewell", epoch: epoch))
        precondition(!flow.responseStarted(id: "unrelated", epoch: epoch))
        precondition(!flow.drained(replyIDs: ["farewell"], epoch: epoch), "a queue gap before generation completes is not final playback")
        precondition(!flow.beginExecuting(epoch: epoch))
        precondition(!flow.responseFinished(id: "unrelated", completed: true, hasAudio: true, epoch: epoch))
        precondition(flow.responseFinished(id: "farewell", completed: true, hasAudio: true, epoch: epoch))
        precondition(flow.phase == .awaitingPlayback && !flow.beginExecuting(epoch: epoch), "response.done must never be treated as heard speech")
        precondition(!flow.drained(replyIDs: ["unrelated"], epoch: epoch))
        precondition(!flow.drained(replyIDs: ["farewell"], epoch: UUID()))
        precondition(flow.drained(replyIDs: ["farewell"], epoch: epoch) && flow.phase == .readyToExit)
        precondition(!flow.drained(replyIDs: ["farewell"], epoch: epoch), "readiness must only be emitted once")
        precondition(!flow.beginExecuting(epoch: UUID()))
        precondition(flow.beginExecuting(epoch: epoch) && flow.pending && flow.freezesScript)
        precondition(!flow.beginExecuting(epoch: epoch))
        precondition(!flow.checkTimeout(now: now.addingTimeInterval(300)) && flow.phase == .executing,
                     "executing waits for its actual result instead of an audio-request timeout")
        precondition(!flow.complete(epoch: UUID(), success: true))
        precondition(flow.complete(epoch: epoch, success: true) && !flow.pending && flow.completionSucceeded == true)
        precondition(!flow.complete(epoch: epoch, success: true) && !flow.cancel() && !flow.request(epoch: UUID(), now: now))

        for audio in [false, true] {
            var failed = PicoMeetingExitFlow()
            precondition(failed.request(epoch: epoch, now: now))
            precondition(failed.markSpeechRequested(epoch: epoch) && failed.responseStarted(id: "failed", epoch: epoch))
            precondition(failed.responseFinished(id: "failed", completed: audio ? false : true, hasAudio: audio, epoch: epoch))
            precondition(failed.phase == .cancelled && !failed.pending && failed.cancellationReason != nil)
            precondition(!failed.drained(replyIDs: ["failed"], epoch: epoch) && !failed.beginExecuting(epoch: epoch),
                         "failed or silent farewell must never leave a meeting")
        }
        var timeout = PicoMeetingExitFlow()
        precondition(timeout.request(epoch: epoch, now: now))
        precondition(!timeout.checkTimeout(now: now.addingTimeInterval(29.9)))
        precondition(timeout.checkTimeout(now: now.addingTimeInterval(30)) && timeout.phase == .cancelled)
        precondition(!timeout.checkTimeout(now: now.addingTimeInterval(31)))
        for stage in 0...3 {
            var cancelled = PicoMeetingExitFlow()
            precondition(cancelled.request(epoch: epoch, now: now))
            if stage > 0 { precondition(cancelled.markSpeechRequested(epoch: epoch)) }
            if stage > 1 { precondition(cancelled.responseStarted(id: "old", epoch: epoch)) }
            if stage > 2 {
                precondition(cancelled.responseFinished(id: "old", completed: true, hasAudio: true, epoch: epoch))
                precondition(cancelled.drained(replyIDs: ["old"], epoch: epoch))
            }
            precondition(cancelled.cancel(reason: "Owner took over or meeting binding changed."))
            precondition(!cancelled.responseStarted(id: "old", epoch: epoch))
            precondition(!cancelled.responseFinished(id: "old", completed: true, hasAudio: true, epoch: epoch))
            precondition(!cancelled.drained(replyIDs: ["old"], epoch: epoch) && !cancelled.beginExecuting(epoch: epoch))
        }
        try ordinaryScriptCompletionDoesNotExit()
        print("PASS: explicit farewell waits for completed audio and actual drain, exits once, fences stale callbacks, cancels failure/timeout, and keeps ordinary script completion in free chat")
    }
    private static func ordinaryScriptCompletionDoesNotExit() throws {
        let script = PicoPresentationScript(deckURL: "https://dg01slides.zoom.us/p/fixture/60000", title: "Fixture",
            slides: [.init(number: 1, title: "One", chunks: [.init(text: "Synthetic fact.")])],
            closing: [.init(text: "Synthetic invitation to continue talking.")])
        var presentation = try PicoPresentationFlow(script: script)
        let exit = PicoMeetingExitFlow()
        precondition(presentation.nextAction() == .requestShare(page: 1))
        precondition(presentation.shareConfirmed(page: 1, generation: presentation.generation))
        var finished = 0
        for _ in 0..<10 {
            guard let action = presentation.nextAction() else { break }
            switch action {
            case .speak(let speech): precondition(presentation.playbackCompleted(id: speech.id, generation: speech.generation))
            case .finished: finished += 1
            default: preconditionFailure("ordinary one-page presentation should only speak and finish")
            }
        }
        precondition(finished == 1 && presentation.phase == .freeChat && presentation.isSharing && presentation.visibleSlide == 1)
        precondition(exit.phase == .idle && !exit.pending && exit.replyID == nil,
                     "finishing a presentation is free conversation, never an automatic meeting-exit request")
    }
}

#if PICO_MEETING_EXIT_STANDALONE
@main struct PicoMeetingExitStandaloneTests {
    static func main() throws { try PicoMeetingExitFlowTests.run() }
}
#endif
