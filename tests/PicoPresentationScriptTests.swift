import Foundation

enum PicoPresentationScriptTests {
    private static func fixture() -> PicoPresentationScript {
        PicoPresentationScript(deckURL: "https://dg01slides.zoom.us/s/synthetic-deck", deckID: "synthetic-deck", title: "Synthetic topic", language: "en-US",
            opening: [.init(id: "open-1", text: "Synthetic greeting question.", waitForReply: true), .init(id: "open-2", text: "Synthetic opening continuation.")],
            shareIntro: [.init(id: "share-1", text: "Synthetic sharing introduction.")],
            slides: (1...3).map { number in PicoScriptSlide(number: number, title: "Synthetic page \(number)",
                chunks: [.init(id: "page-\(number)-1", text: "Synthetic first fact for page \(number)."),
                         .init(id: "page-\(number)-2", text: "Synthetic second fact for page \(number).")], pageID: "\(number * 10000)") },
            closing: [.init(id: "close-1", text: "Synthetic closing sentence one."), .init(id: "close-2", text: "Synthetic closing sentence two.")])
    }
    private static func speech(_ action: PicoScriptAction?) -> PicoScriptSpeech {
        guard case .speak(let value) = action else { preconditionFailure("Expected a speech action") }; return value
    }
    private static func rejected(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Expected validation failure") }
        catch { precondition(!error.localizedDescription.isEmpty) }
    }
    private static func confirmedFlow() throws -> PicoPresentationFlow {
        var script = fixture(); script.opening = []; script.shareIntro = []
        var flow = try PicoPresentationFlow(script: script)
        precondition(flow.nextAction() == .requestShare(page: 1))
        precondition(flow.shareConfirmed(page: 1, generation: flow.generation))
        return flow
    }
    static func run() throws {
        let script = fixture()
        let encoded = try JSONEncoder().encode(script)
        let decoded = try PicoPresentationScript.decode(encoded)
        precondition(decoded == script)
        let minimal = Data(#"{"deckURL":"https://slides.zoom.us/s/other-deck","title":"Synthetic","slides":[{"number":1,"title":"One","chunks":[{"text":"Synthetic fact."}]}]}"#.utf8)
        let old = try PicoPresentationScript.decode(minimal)
        precondition(old.version == 1 && old.language == "zh-CN" && old.deckID == nil)
        precondition(old.deckSlideCount == nil && old.totalDeckSlides == 1 && old.closingStartSlide == nil)
        precondition(!old.slides[0].chunks[0].waitForExplicitContinue)
        precondition(old.slides[0].pageID == nil && !old.slides[0].chunks[0].waitForReply && !old.slides[0].chunks[0].id.isEmpty)
        precondition(old.slides[0].chunks[0].replyTimeoutSeconds == 12,
                     "older saved scripts receive the default without reimporting")
        let disabled = try JSONDecoder().decode(PicoScriptChunk.self,
            from: Data(#"{"id":"disabled","text":"Wait","waitForReply":true,"replyTimeoutSeconds":null}"#.utf8))
        precondition(disabled.replyTimeoutSeconds == nil)
        let roundTrip = try JSONDecoder().decode(PicoScriptChunk.self, from: JSONEncoder().encode(disabled))
        precondition(roundTrip == disabled, "explicit null must stay disabled after saving the script")
        for url in ["http://dg01slides.zoom.us/s/deck", "https://example.com/deck", "https://slides.zoom.us.evil.example/s/deck",
                    "https://zoom.us/j/123", "https://user:secret@slides.zoom.us/s/deck", "https://slides.zoom.us:8443/s/deck", "file:///tmp/deck", "https://slides.zoom.us/"] {
            var invalid = script; invalid.deckURL = url; rejected { try invalid.validate() }
        }
        var invalid = script; invalid.slides[1].number = 4; rejected { try invalid.validate() }
        invalid = script; invalid.slides[0].chunks = []; rejected { try invalid.validate() }
        invalid = script; invalid.slides[0].chunks[0].text = String(repeating: "a", count: 801); rejected { try invalid.validate() }
        invalid = script; invalid.opening[1].id = invalid.opening[0].id; rejected { try invalid.validate() }
        invalid = script; invalid.deckID = "bad/id"; rejected { try invalid.validate() }
        invalid = script; invalid.slides[0].pageID = "bad/id"; rejected { try invalid.validate() }
        for timeout in [0.0, -1, 121, .infinity, .nan] {
            invalid = script; invalid.opening[0].replyTimeoutSeconds = timeout; rejected { try invalid.validate() }
        }
        invalid = script; invalid.opening[0].replyTimeoutTransition = " "; rejected { try invalid.validate() }
        rejected { _ = try PicoPresentationScript.decode(Data(count: 512 * 1024 + 1)) }

        var gap = try confirmedFlow()
        let completedBeforeQuestion = speech(gap.nextAction())
        precondition(gap.playbackCompleted(id: completedBeforeQuestion.id, generation: completedBeforeQuestion.generation))
        let gapCursor = gap.cursor
        let gapAnswer = gap.beginAnswer()
        precondition(gap.nextAction() == nil)
        precondition(gap.answerPlaybackCompleted(id: gapAnswer) && gap.cursor == gapCursor)
        let afterGap = speech(gap.nextAction())
        precondition(afterGap.chunkID == "page-1-2" && afterGap.needsTransition,
                     "a question between fully played chunks still needs a natural transition")

        var flow = try PicoPresentationFlow(script: script)
        let greeting = speech(flow.nextAction())
        precondition(flow.cursor.chunkIndex == 0 && flow.nextAction() == nil)
        precondition(!flow.playbackCompleted(id: UUID(), generation: greeting.generation))
        precondition(flow.playbackCompleted(id: greeting.id, generation: greeting.generation))
        precondition(flow.cursor.chunkIndex == 1 && flow.nextAction() == .waitForReply)
        for _ in 0..<20 { precondition(flow.nextAction() == nil, "waiting must have no implicit timeout") }
        flow.guestReplyReceived()
        let answer = flow.beginAnswer(), beforeAnswer = flow.cursor
        precondition(flow.nextAction() == nil && flow.cursor == beforeAnswer)
        precondition(!flow.answerPlaybackCompleted(id: UUID()) && flow.nextAction() == nil)
        precondition(flow.answerPlaybackCompleted(id: answer) && flow.cursor == beforeAnswer)
        let secondOpening = speech(flow.nextAction())
        precondition(secondOpening.chunkID == "open-2" && !secondOpening.needsTransition,
                     "the expected opening greeting answer should not add an interruption bridge")
        precondition(flow.playbackCompleted(id: secondOpening.id, generation: secondOpening.generation))
        let shareIntro = speech(flow.nextAction())
        precondition(shareIntro.chunkID == "share-1")
        precondition(flow.playbackCompleted(id: shareIntro.id, generation: shareIntro.generation))
        precondition(flow.nextAction() == .requestShare(page: 1) && flow.nextAction() == nil)
        precondition(!flow.shareConfirmed(page: 2, generation: flow.generation))
        precondition(!flow.shareConfirmed(page: 1, generation: UUID()))
        precondition(flow.shareConfirmed(page: 1, generation: flow.generation))
        precondition(flow.isSharing && flow.visibleSlide == 1)

        let interrupted = speech(flow.nextAction()), interruptedCursor = flow.cursor
        flow.interrupt()
        precondition(flow.isPaused && flow.cursor == interruptedCursor && flow.nextAction() == nil)
        precondition(!flow.playbackCompleted(id: interrupted.id, generation: interrupted.generation))
        let question = flow.beginAnswer()
        precondition(flow.answerPlaybackCompleted(id: question) && flow.cursor == interruptedCursor)
        flow.resume()
        let resumed = speech(flow.nextAction())
        precondition(resumed.chunkID == interrupted.chunkID && resumed.needsTransition && resumed.id != interrupted.id)
        precondition(flow.playbackCompleted(id: resumed.id, generation: resumed.generation))
        let next = speech(flow.nextAction()), reviewCursor = flow.cursor
        precondition(!next.needsTransition && next.chunkID == "page-1-2")
        let review = try flow.jumpToSlide(3)
        precondition(review == .showSlide(page: 3))
        let reviewGeneration = flow.generation
        precondition(!flow.slideShown(page: 3, generation: next.generation))
        precondition(flow.slideShown(page: 3, generation: reviewGeneration))
        precondition(flow.visibleSlide == 3 && flow.cursor == reviewCursor && flow.nextAction() == nil)
        precondition(!flow.playbackCompleted(id: next.id, generation: next.generation))
        let reviewAnswer = flow.beginAnswer()
        flow.resume()
        precondition(flow.nextAction() == nil, "resume cannot bypass pending ordinary answer playback")
        precondition(flow.answerPlaybackCompleted(id: reviewAnswer))
        precondition(flow.nextAction() == .showSlide(page: 1))
        precondition(flow.nextAction() == nil && flow.slideShown(page: 1, generation: flow.generation))
        let restored = speech(flow.nextAction())
        precondition(restored.chunkID == next.chunkID && restored.needsTransition)
        precondition(flow.playbackCompleted(id: restored.id, generation: restored.generation))

        var completed: [String] = [], finished = 0
        for _ in 0..<30 {
            guard let action = flow.nextAction() else { break }
            switch action {
            case .speak(let value):
                completed.append(value.chunkID)
                precondition(flow.playbackCompleted(id: value.id, generation: value.generation))
            case .showSlide(let page): precondition(flow.slideShown(page: page, generation: flow.generation))
            case .finished: finished += 1
            default: preconditionFailure("Unexpected action in continuous presentation")
            }
        }
        precondition(completed == ["page-2-1", "page-2-2", "page-3-1", "page-3-2", "close-1", "close-2"])
        precondition(finished == 1 && flow.phase == .freeChat && flow.isSharing && flow.visibleSlide == 3)
        precondition(flow.nextAction() == nil)
        let finalReview = try flow.jumpToSlide(1)
        precondition(finalReview == .showSlide(page: 1))
        precondition(flow.slideShown(page: 1, generation: flow.generation))
        flow.resume()
        precondition(flow.phase == .freeChat && flow.visibleSlide == 1 && flow.nextAction() == nil,
                     "reviewing a finished deck must not restart its presentation or closing")

        var takeover = try confirmedFlow()
        let oldSpeech = speech(takeover.nextAction()), oldCursor = takeover.cursor
        takeover.takeOver()
        precondition(takeover.isTakenOver && takeover.cursor == oldCursor && takeover.nextAction() == nil)
        let staleAnswer = takeover.beginAnswer()
        precondition(takeover.answerID == nil && !takeover.answerPlaybackCompleted(id: staleAnswer))
        precondition(!takeover.playbackCompleted(id: oldSpeech.id, generation: oldSpeech.generation))
        takeover.resume()
        let afterTakeover = speech(takeover.nextAction())
        precondition(afterTakeover.chunkID == oldSpeech.chunkID && afterTakeover.needsTransition)
        let obsoleteAnswer = takeover.beginAnswer()
        takeover.cancel()
        precondition(!takeover.answerPlaybackCompleted(id: obsoleteAnswer))
        precondition(!takeover.playbackCompleted(id: afterTakeover.id, generation: afterTakeover.generation))
        takeover.resume()
        precondition(takeover.phase == .cancelled && takeover.nextAction() == nil)
        var cancelledPage = try confirmedFlow()
        let pageAction = try cancelledPage.jumpToSlide(2), obsoletePageGeneration = cancelledPage.generation
        precondition(pageAction == .showSlide(page: 2))
        cancelledPage.takeOver()
        precondition(!cancelledPage.slideShown(page: 2, generation: obsoletePageGeneration))
        rejected { _ = try cancelledPage.jumpToSlide(99) }
        try earlyConclude()
        try explicitContinueReleasesReplyWait()
        try replyTimeoutTransitionRequiresPlayback()
        try persistentDiscussionAndPreparedClosing()
        print("PASS: generic Codable validation, backward-compatible/null-disabled reply timeout, scoped silence-bridge playback without cursor skips, separate Q&A playback, share/page confirmations, interrupted transitions, free-chat retention and takeover/cancel generation fences. No UI, network, model or meeting used.")
    }
    private static func replyTimeoutTransitionRequiresPlayback() throws {
        var script = fixture()
        script.opening[0].replyTimeoutSeconds = 4
        script.opening[0].replyTimeoutTransition = "Let me continue. You can jump in."
        var flow = try PicoPresentationFlow(script: script)
        precondition(flow.requestReplyTimeoutTransition() == nil, "a timeout cannot run before a configured wait")
        let greeting = speech(flow.nextAction())
        precondition(flow.requestReplyTimeoutTransition() == nil)
        precondition(flow.playbackCompleted(id: greeting.id, generation: greeting.generation))
        let cursor = flow.cursor
        precondition(flow.replyWait?.timeoutSeconds == 4)
        let bridge = flow.requestReplyTimeoutTransition()!
        precondition(bridge.isReplyTimeoutTransition && bridge.text == "Let me continue. You can jump in.")
        precondition(flow.cursor == cursor && flow.waitingForReply && flow.nextAction() == nil)
        precondition(flow.requestReplyTimeoutTransition() == nil, "only one transition may be in flight")
        precondition(!flow.playbackCompleted(id: bridge.id, generation: UUID()))
        flow.interrupt()
        precondition(!flow.playbackCompleted(id: bridge.id, generation: bridge.generation))
        flow.resume()
        let retry = flow.requestReplyTimeoutTransition()!
        precondition(retry.id != bridge.id && flow.cursor == cursor)
        precondition(flow.playbackCompleted(id: retry.id, generation: retry.generation))
        precondition(!flow.waitingForReply && flow.replyWait == nil && flow.cursor == cursor)
        precondition(!flow.playbackCompleted(id: retry.id, generation: retry.generation))
        precondition(flow.requestReplyTimeoutTransition() == nil)
        let next = speech(flow.nextAction())
        precondition(next.chunkID == "open-2" && !next.needsTransition,
                     "a played silence transition releases exactly the wait and never commits another script chunk")

        script.opening[0].replyTimeoutSeconds = nil
        var unlimited = try PicoPresentationFlow(script: script)
        let question = speech(unlimited.nextAction())
        precondition(unlimited.playbackCompleted(id: question.id, generation: question.generation))
        precondition(unlimited.waitingForReply && unlimited.requestReplyTimeoutTransition() == nil)
        unlimited.takeOver(); precondition(unlimited.requestReplyTimeoutTransition() == nil)
        unlimited.cancel(); precondition(unlimited.requestReplyTimeoutTransition() == nil)
    }
    private static func earlyConclude() throws {
        var shared = try confirmedFlow()
        let oldSpeech = speech(shared.nextAction()), oldGeneration = shared.generation
        let review = try shared.jumpToSlide(2)
        precondition(review == .showSlide(page: 2))
        precondition(shared.slideShown(page: 2, generation: shared.generation))
        precondition(shared.requestConclude() && shared.phase == .closing && !shared.isPaused)
        precondition(shared.visibleSlide == 2 && shared.slideIndex == 0 && shared.isSharing,
                     "early wrap-up keeps the displayed page and does not mark skipped slides as played")
        precondition(!shared.playbackCompleted(id: oldSpeech.id, generation: oldGeneration))
        let first = speech(shared.nextAction()), closingGeneration = shared.generation
        precondition(first.chunkID == "close-1" && !shared.requestConclude() && shared.generation == closingGeneration)
        precondition(shared.playbackCompleted(id: first.id, generation: first.generation))
        let second = speech(shared.nextAction())
        precondition(second.chunkID == "close-2")
        precondition(shared.playbackCompleted(id: second.id, generation: second.generation))
        precondition(shared.nextAction() == .finished && shared.phase == .freeChat && shared.visibleSlide == 2 && shared.isSharing)
        precondition(!shared.requestConclude() && shared.nextAction() == nil, "completed wrap-up must never restart its closing")

        var script = fixture(); script.opening = []; script.shareIntro = []
        script.closing[0].waitForReply = true
        var unshared = try PicoPresentationFlow(script: script)
        precondition(unshared.nextAction() == .requestShare(page: 1))
        let pendingShare = unshared.generation
        precondition(unshared.requestConclude())
        precondition(!unshared.shareConfirmed(page: 1, generation: pendingShare))
        for expected in ["close-1", "close-2"] {
            let value = speech(unshared.nextAction()); precondition(value.chunkID == expected)
            precondition(unshared.playbackCompleted(id: value.id, generation: value.generation))
        }
        precondition(unshared.nextAction() == .finished && !unshared.isSharing && unshared.visibleSlide == nil,
                     "early wrap-up before sharing must not trigger sharing, navigation or another scripted wait")

        var blocked = try confirmedFlow(); blocked.takeOver()
        precondition(!blocked.requestConclude() && blocked.isTakenOver)
        blocked.cancel(); precondition(!blocked.requestConclude() && blocked.phase == .cancelled)
    }
    private static func explicitContinueReleasesReplyWait() throws {
        var flow = try PicoPresentationFlow(script: fixture())
        let greeting = speech(flow.nextAction())
        precondition(flow.playbackCompleted(id: greeting.id, generation: greeting.generation))
        precondition(flow.nextAction() == .waitForReply)
        flow.interrupt(); flow.resume()
        precondition(flow.waitingForReply && flow.answerID == nil && flow.nextAction() == nil,
                     "connection recovery must retain the greeting wait without creating a model answer barrier")
        flow.resume(continuePastReplyWait: true)
        precondition(!flow.waitingForReply && flow.answerID == nil)
        let next = speech(flow.nextAction())
        precondition(next.chunkID == "open-2", "explicit continue must release the greeting wait and proceed to the next unplayed chunk")
    }
    private static func discussionFixture() -> PicoPresentationScript {
        PicoPresentationScript(deckURL: "https://slides.zoom.us/p/discussion-deck", title: "Discussion fixture",
            slides: [
                .init(number: 1, title: "Progress", chunks: [.init(id: "progress", text: "Prepared progress.")]),
                .init(number: 2, title: "Questions", chunks: [.init(id: "questions", text: "Let's discuss your questions.",
                    waitForReply: true, replyTimeoutSeconds: nil, waitForExplicitContinue: true)]),
                .init(number: 3, title: "Thanks", chunks: [.init(id: "thanks", text: "Thank you.")])
            ], closing: [], deckSlideCount: 5, closingStartSlide: 3)
    }
    private static func discussionFlow() throws -> PicoPresentationFlow {
        var flow = try PicoPresentationFlow(script: discussionFixture())
        precondition(flow.nextAction() == .requestShare(page: 1))
        precondition(flow.shareConfirmed(page: 1, generation: flow.generation))
        let progress = speech(flow.nextAction())
        precondition(flow.playbackCompleted(id: progress.id, generation: progress.generation))
        precondition(flow.nextAction() == .showSlide(page: 2))
        precondition(flow.slideShown(page: 2, generation: flow.generation))
        let questions = speech(flow.nextAction())
        precondition(flow.playbackCompleted(id: questions.id, generation: questions.generation))
        precondition(flow.nextAction() == .waitForReply && flow.waitingForExplicitContinue)
        return flow
    }
    private static func persistentDiscussionAndPreparedClosing() throws {
        let script = discussionFixture()
        let decoded = try PicoPresentationScript.decode(JSONEncoder().encode(script))
        precondition(decoded == script)
        for count in [0, 2, 61] {
            var invalid = script; invalid.deckSlideCount = count; rejected { try invalid.validate() }
        }
        for start in [0, 4] {
            var invalid = script; invalid.closingStartSlide = start; rejected { try invalid.validate() }
        }
        var invalid = script; invalid.slides[1].chunks[0].waitForReply = false
        rejected { try invalid.validate() }
        invalid = script; invalid.slides[1].chunks[0].replyTimeoutSeconds = 12
        rejected { try invalid.validate() }

        var flow = try discussionFlow(), cursor = flow.cursor
        for _ in 0..<3 {
            flow.interrupt(); flow.guestReplyReceived()
            let answer = flow.beginAnswer()
            precondition(flow.answerPlaybackCompleted(id: answer))
            flow.resume()
            precondition(flow.waitingForReply && flow.waitingForExplicitContinue && flow.cursor == cursor)
            precondition(flow.nextAction() == nil && flow.requestReplyTimeoutTransition() == nil,
                         "ordinary questions, answer completion and reconnect must not release a discussion gate")
        }
        let appendixReview = try flow.jumpToSlide(5)
        precondition(appendixReview == .showSlide(page: 5))
        precondition(flow.slideShown(page: 5, generation: flow.generation))
        flow.resume()
        precondition(flow.waitingForExplicitContinue && flow.cursor == cursor && flow.visibleSlide == 5 && flow.nextAction() == nil,
                     "appendix review must keep the prepared cursor and discussion gate intact")
        flow.takeOver(); flow.resume()
        precondition(flow.waitingForExplicitContinue && flow.nextAction() == nil)
        flow.resume(continuePastReplyWait: true)
        precondition(!flow.waitingForReply && !flow.waitingForExplicitContinue)
        precondition(flow.nextAction() == .showSlide(page: 3))
        precondition(flow.slideShown(page: 3, generation: flow.generation))
        let thanks = speech(flow.nextAction())
        precondition(thanks.chunkID == "thanks" && !flow.canConclude && !flow.requestConclude(),
                     "a normal explicit continuation into the closing section cannot restart it")
        precondition(flow.playbackCompleted(id: thanks.id, generation: thanks.generation))
        precondition(flow.nextAction() == .finished && flow.phase == .freeChat && flow.visibleSlide == 3)
        precondition(flow.nextAction() == nil, "unprepared appendix pages are never presented automatically")

        flow = try discussionFlow(); cursor = flow.cursor
        precondition(flow.canConclude && flow.requestConclude() && !flow.waitingForReply)
        let endingGeneration = flow.generation
        precondition(!flow.requestConclude() && flow.generation == endingGeneration,
                     "duplicate conclusions cannot invalidate a pending page/speech operation")
        precondition(flow.nextAction() == .showSlide(page: 3))
        precondition(flow.slideShown(page: 3, generation: flow.generation))
        let ending = speech(flow.nextAction())
        precondition(ending.chunkID == "thanks" && ending.slideNumber == 3 && !flow.requestConclude())
        precondition(flow.playbackCompleted(id: ending.id, generation: ending.generation))
        precondition(flow.nextAction() == .finished && flow.visibleSlide == 3 && flow.isSharing)

        var early = script; early.closing = [.init(id: "fallback", text: "Thank you for your time.")]
        var beforeShare = try PicoPresentationFlow(script: early)
        precondition(beforeShare.requestConclude())
        let fallback = speech(beforeShare.nextAction())
        precondition(fallback.chunkID == "fallback" && fallback.slideNumber == nil)
        precondition(beforeShare.playbackCompleted(id: fallback.id, generation: fallback.generation))
        precondition(beforeShare.nextAction() == .finished && !beforeShare.isSharing && beforeShare.visibleSlide == nil,
                     "configured closing pages do not authorize starting sharing before a deck was shared")
        print("PASS: persistent discussion across multiple answers, review, pause/reconnect and takeover; explicit-only continuation/conclusion; prepared closing-page idempotency; appendix count and review without automatic presentation")
    }
}

#if PICO_SCRIPT_STANDALONE
@main struct PicoPresentationScriptStandaloneTests {
    static func main() throws { try PicoPresentationScriptTests.run() }
}
#endif
