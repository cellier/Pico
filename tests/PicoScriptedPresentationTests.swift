import Foundation

@MainActor enum PicoScriptedPresentationTests {
    static func run() async throws {
        try await openingWaitAndPlayback()
        try await pageConfirmationAndFreeChatReview()
        try await interruptionAndTakeover()
        try await explicitResumeResynchronizes()
        try await cancelledSharingAndUnknownStatus()
        try await refusedSpeechIsRetried()
        try await toolOnlyResponseKeepsSpeechToken()
        try await noAudioReplyFailsVisibly()
        try await proactiveQuestionResumesAfterAnswer()
        try await questionPermissionHold()
        try await alreadySharedDeckRestartsAtFirstPage()
        try await resumeWaitsForCancelledOperation()
        try await busyStatusReadIsRetried()
        try await pausedReviewPreservesAgenda()
        try await concludeUsesClosingOnceAndKeepsSharedPage()
        try await concludeBeforeSharingDoesNotOperateZoom()
        try await configureResetsOnlyForNewSessions()
        try await newConfigureRejectsOldMeetingResult()
        try await explicitContinueReleasesOpeningWait()
        try await automaticResponseCannotBorrowScriptScope()
        try await lateTranscriptPreservesOrdinaryPlayback()
        try await replyTimeoutStartsAtPlaybackAndKeepsCursor()
        try await replyTimeoutPausesForRemoteProcessing()
        try await discardedVADRestoresReplyTimeout()
        try await replyTimeoutCannotOverrideHumanControl()
        try await realReplyAndInterruptedTimeoutKeepPlaybackBarriers()
        print("PASS: scripted presentation confirms pages/playback, rejects silent and stale replies, waits for real questions, resumes after answers, preserves final-page sharing/review, and handles configurable silence fallback without overriding VAD, Q&A, permission hold or owner control")
    }

    private static func fixture(opening: Bool = false) -> PicoPresentationScript {
        PicoPresentationScript(deckURL: "https://dg01slides.zoom.us/p/fixture/60000", title: "Fixture",
            opening: opening ? [.init(id: "hello", text: "你好，今天怎么样？", waitForReply: true, replyTimeoutSeconds: nil)] : [],
            shareIntro: opening ? [.init(id: "share-intro", text: "我准备了几页，我们边看边聊。 ")] : [],
            slides: [.init(number: 1, title: "One", chunks: [.init(id: "one", text: "第一部分。")]),
                     .init(number: 2, title: "Two", chunks: [.init(id: "two", text: "第二部分。")])],
            closing: [.init(id: "closing", text: "好，介绍就到这里。接下来我们随便聊聊。你有什么想问我的，都可以。")])
    }
    private static func settle() async { for _ in 0..<12 { await Task.yield() } }
    private static func tick(_ coordinator: PicoScriptedPresentation, _ speech: inout [PicoScriptSpeech]) {
        coordinator.tick(canSpeak: true) { speech.append($0); return true }
    }
    private static func played(_ coordinator: PicoScriptedPresentation, id: String, script: PicoScriptSpeech? = nil) {
        coordinator.responseStarted(id: id, scriptSpeechID: script?.id); coordinator.responseFinished(id: id, completed: true, hasAudio: true)
        coordinator.rendered(replyIDs: [id])
    }
    private static func shared(_ coordinator: PicoScriptedPresentation, _ speech: inout [PicoScriptSpeech]) async {
        tick(coordinator, &speech); await settle()
        precondition(coordinator.sharing && coordinator.currentSlide == 1)
    }

    private static func openingWaitAndPlayback() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture(opening: true))
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); await settle()
        precondition(fake.shares == 0 && fake.reads == 0 && speech.isEmpty, "configure/tick without start must never inspect or operate Zoom")
        coordinator.start(); tick(coordinator, &speech)
        precondition(speech.count == 1 && speech[0].chunkID == "hello")
        coordinator.responseStarted(id: "hello-reply", scriptSpeechID: speech.last!.id)
        coordinator.responseFinished(id: "hello-reply", completed: true)
        clock.advance(20); tick(coordinator, &speech)
        precondition(speech.count == 1 && coordinator.cursor?.chunkIndex == 0, "generation done cannot commit an unheard opening")
        coordinator.rendered(replyIDs: ["hello-reply"])
        clock.advance(20); tick(coordinator, &speech)
        precondition(coordinator.waitingForReply && speech.count == 1 && fake.shares == 0, "an explicitly unlimited wait must wait for a real guest")
        coordinator.interrupted(); coordinator.guestTranscript(text: "今天还不错。")
        coordinator.responseStarted(id: "greeting-answer")
        coordinator.responseFinished(id: "greeting-answer", completed: true)
        clock.advance(20); tick(coordinator, &speech)
        precondition(speech.count == 1 && fake.shares == 0, "ordinary answer generation must not start sharing or advance the script")
        coordinator.rendered(replyIDs: ["greeting-answer"])
        clock.advance(2); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.chunkID == "share-intro")
    }

    private static func pageConfirmationAndFreeChatReview() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech)
        precondition(speech.isEmpty && fake.shares == 1)
        tick(coordinator, &speech); precondition(speech.last?.slideNumber == 1)
        coordinator.responseStarted(id: "one", scriptSpeechID: speech.last!.id)
        coordinator.rendered(replyIDs: ["one"])
        tick(coordinator, &speech)
        precondition(fake.pages.isEmpty && speech.count == 1, "render drain alone still needs successful provider completion")
        coordinator.responseFinished(id: "one", completed: true)
        clock.advance(0.8); tick(coordinator, &speech); await settle()
        precondition(fake.pages == [2] && coordinator.currentSlide == 2 && speech.count == 1, "confirm the next page before speaking its script")
        tick(coordinator, &speech); precondition(speech.last?.slideNumber == 2)
        played(coordinator, id: "two", script: speech.last)
        clock.advance(0.8); tick(coordinator, &speech)
        precondition(speech.last?.chunkID == "closing" && coordinator.currentSlide == 2)
        played(coordinator, id: "closing", script: speech.last)
        clock.advance(0.8); tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(coordinator.isFreeChat && coordinator.sharing && coordinator.currentSlide == 2)
        let count = speech.count
        let outcome = await coordinator.navigate(page: 1)
        precondition(outcome.contains("true") && coordinator.currentSlide == 1 && coordinator.isFreeChat)
        tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(speech.count == count && fake.pages == [2, 1], "free-chat review must not replay or restart the presentation")
    }

    private static func interruptionAndTakeover() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech); tick(coordinator, &speech)
        coordinator.responseStarted(id: "partial", scriptSpeechID: speech.last!.id)
        coordinator.responseFinished(id: "partial", completed: true)
        coordinator.interrupted(); coordinator.guestTranscript(text: "可以举个例子吗？")
        coordinator.rendered(replyIDs: ["partial"])
        precondition(coordinator.cursor?.chunkIndex == 0, "late drain of an interrupted response cannot commit a script chunk")
        coordinator.responseStarted(id: "answer"); coordinator.responseFinished(id: "answer", completed: true)
        clock.advance(1); tick(coordinator, &speech)
        precondition(speech.count == 1, "wait for actual answer playback")
        coordinator.rendered(replyIDs: ["answer"])
        clock.advance(1.3); tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.needsTransition == true && speech.last?.chunkID == "one")
        coordinator.responseStarted(id: "resumed", scriptSpeechID: speech.last!.id)
        coordinator.takeOver()
        coordinator.responseFinished(id: "resumed", completed: true); coordinator.rendered(replyIDs: ["resumed"])
        clock.advance(20); tick(coordinator, &speech)
        precondition(!coordinator.running && speech.count == 2 && fake.pages.isEmpty && coordinator.cursor?.chunkIndex == 0)
        coordinator.guestTranscript(text: "继续吧")
        precondition(!coordinator.running, "guest speech cannot release owner takeover")
        coordinator.resume(); tick(coordinator, &speech); await settle()
        clock.advance(0.7); tick(coordinator, &speech)
        precondition(coordinator.running && speech.count == 3 && speech.last?.needsTransition == true)
    }

    private static func cancelledSharingAndUnknownStatus() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        fake.deferShare = true
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); await settle()
        precondition(fake.shares == 1 && fake.shareContinuation != nil)
        coordinator.pause(); fake.releaseShare(); await settle()
        precondition(!coordinator.sharing && coordinator.isPaused && speech.isEmpty, "a late successful share callback cannot resume a paused run")
        coordinator.resume(); clock.advance(1); tick(coordinator, &speech); await settle()
        precondition(coordinator.sharing)
        fake.snapshot.sharing = .unknown
        var failures = 0; coordinator.onFailure = { _ in failures += 1 }
        clock.advance(2); tick(coordinator, &speech); await settle()
        precondition(coordinator.isPaused && !coordinator.running && failures == 1 && speech.isEmpty, "unknown sharing/page state must visibly pause before another line")
    }

    private static func explicitResumeResynchronizes() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech); tick(coordinator, &speech)
        coordinator.responseStarted(id: "interrupted-script", scriptSpeechID: speech.last!.id)
        coordinator.interrupted(); coordinator.guestTranscript(text: "讲个例子。")
        coordinator.responseStarted(id: "answer-before-resume")
        fake.snapshot.currentSlide = 2 // An owner changed the page while the agent was paused.
        coordinator.resume(); tick(coordinator, &speech); await settle()
        precondition(coordinator.currentSlide == 2 && coordinator.running)
        coordinator.responseFinished(id: "answer-before-resume", completed: true)
        coordinator.rendered(replyIDs: ["answer-before-resume"])
        clock.advance(0.7); tick(coordinator, &speech); await settle()
        precondition(coordinator.currentSlide == 1 && fake.pages == [1], "explicit resume confirms the real page, then restores the unfinished agenda page")
        tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.chunkID == "one", "aborted ordinary answer cannot leave a stale barrier blocking an explicit resume")
    }

    private static func refusedSpeechIsRetried() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture(opening: true)); coordinator.start()
        var attempts: [PicoScriptSpeech] = []
        coordinator.tick(canSpeak: false) { attempts.append($0); return true }
        precondition(attempts.isEmpty)
        coordinator.tick(canSpeak: true) { attempts.append($0); return false }
        coordinator.tick(canSpeak: true) { attempts.append($0); return true }
        precondition(attempts.count == 2 && attempts[0] == attempts[1], "a busy realtime client retries the same uncommitted chunk")
        coordinator.tick(canSpeak: true) { attempts.append($0); return true }
        precondition(attempts.count == 2, "accepted speech is never resubmitted while waiting for its response ID")
    }

    private static func toolOnlyResponseKeepsSpeechToken() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture(opening: true)); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech)
        coordinator.responseStarted(id: "tool-only-response", scriptSpeechID: speech.last!.id)
        // The realtime client intentionally does not emit spoken-completion for a tool call.
        coordinator.responseStarted(id: "spoken-after-tool", scriptSpeechID: speech.last!.id)
        coordinator.responseFinished(id: "spoken-after-tool", completed: true)
        coordinator.rendered(replyIDs: ["spoken-after-tool"])
        precondition(coordinator.cursor?.chunkIndex == 1 && coordinator.waitingForReply,
                     "tool-only generation cannot consume or lose the pending script playback token")
        coordinator.responseFinished(id: "tool-only-response", completed: true, hasAudio: false)
        coordinator.responseFinished(id: "spoken-after-tool", completed: true, hasAudio: true)
        coordinator.rendered(replyIDs: ["spoken-after-tool", "tool-only-response"])
        precondition(coordinator.cursor?.chunkIndex == 1 && coordinator.running && coordinator.waitingForReply,
                     "late/duplicate tool aliases cannot replay, commit twice or trigger a false missing-audio failure")
    }

    private static func noAudioReplyFailsVisibly() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture(opening: true)); coordinator.start()
        var speech: [PicoScriptSpeech] = [], failures: [String] = []
        coordinator.onFailure = { failures.append($0) }
        tick(coordinator, &speech); coordinator.responseStarted(id: "silent", scriptSpeechID: speech.last!.id)
        coordinator.responseFinished(id: "silent", completed: true, hasAudio: false)
        clock.advance(30); tick(coordinator, &speech)
        coordinator.rendered(replyIDs: ["silent"])
        precondition(coordinator.isPaused && !coordinator.running && coordinator.cursor?.chunkIndex == 0 && failures.count == 1 && coordinator.status.contains("没有收到"),
                     "successful generation without any accepted audio must fail visibly, never hang or advance")
        coordinator.resume(); clock.advance(1); tick(coordinator, &speech)
        played(coordinator, id: "actual-opening", script: speech.last)
        coordinator.interrupted(); coordinator.guestTranscript(text: "挺好的。")
        coordinator.responseStarted(id: "silent-answer")
        coordinator.responseFinished(id: "silent-answer", completed: true, hasAudio: false)
        precondition(coordinator.isPaused && !coordinator.running && fake.shares == 0 && failures.count == 2,
                     "a silent ordinary answer cannot release the greeting wait and begin sharing")
    }

    private static func proactiveQuestionResumesAfterAnswer() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        var script = fixture(); script.slides[0].chunks[0].waitForReply = true
        script.slides[0].chunks[0].replyTimeoutSeconds = nil
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(script); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech); tick(coordinator, &speech); played(coordinator, id: "prompt", script: speech.last)
        clock.advance(20); tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(coordinator.waitingForReply && fake.pages.isEmpty && speech.count == 1)
        coordinator.interrupted(); coordinator.guestTranscript(text: "我觉得这个思路挺好。")
        coordinator.responseStarted(id: "response-to-guest")
        coordinator.responseFinished(id: "response-to-guest", completed: true, hasAudio: true)
        tick(coordinator, &speech); precondition(fake.pages.isEmpty)
        coordinator.rendered(replyIDs: ["response-to-guest"])
        clock.advance(1.3); tick(coordinator, &speech); await settle()
        tick(coordinator, &speech)
        precondition(fake.pages == [2] && speech.count == 2 && speech.last?.chunkID == "two" && speech.last?.needsTransition == true,
                     "after a proactive question, resume only after the actual ordinary answer; do not repeat the completed question chunk")
    }

    private static func questionPermissionHold() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech); tick(coordinator, &speech)
        coordinator.responseStarted(id: "interrupted-by-permission", scriptSpeechID: speech.last!.id)
        coordinator.interrupted(); coordinator.holdForQuestion()
        played(coordinator, id: "permission-acknowledgement")
        clock.advance(20); tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(coordinator.waitingForQuestion && coordinator.isPaused && coordinator.running && speech.count == 1,
                     "a played 'yes, please ask' acknowledgement must not restart the presentation")
        coordinator.guestTranscript(text: "你为什么能了解我？")
        played(coordinator, id: "actual-answer")
        clock.advance(1.3); tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(!coordinator.waitingForQuestion && speech.count == 2 && speech.last?.needsTransition == true)
        coordinator.pause(); coordinator.guestTranscript(text: "为什么？")
        played(coordinator, id: "answer-during-explicit-pause")
        clock.advance(20); tick(coordinator, &speech)
        precondition(coordinator.isPaused && !coordinator.running && speech.count == 2,
                     "an explicit pause must not be revoked by an unrelated question or its playback")
    }

    private static func alreadySharedDeckRestartsAtFirstPage() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        fake.snapshot.currentSlide = 2
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech)
        precondition(fake.shares == 1 && fake.pages == [1] && speech.isEmpty,
                     "an existing shared deck on a later page must be explicitly returned to the first page before narration")
        tick(coordinator, &speech); precondition(speech.last?.slideNumber == 1)
    }

    private static func resumeWaitsForCancelledOperation() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        fake.deferShare = true
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); await settle()
        coordinator.pause(); coordinator.resume(); clock.advance(1)
        tick(coordinator, &speech); await settle()
        precondition(fake.shares == 1 && !coordinator.sharing, "resume must wait for the cancelled previous driver operation, instead of triggering busy failure")
        fake.releaseShare(); await settle()
        precondition(fake.shares == 2 && coordinator.sharing && coordinator.running && !coordinator.isPaused)
    }

    private static func busyStatusReadIsRetried() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech)
        fake.readFailures = [.busy]
        clock.advance(2); tick(coordinator, &speech); await settle()
        precondition(coordinator.running && !coordinator.isPaused && speech.isEmpty)
        tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(fake.reads == 2 && speech.count == 1, "a draining driver busy state must be rechecked, not reported as meeting loss")
    }

    private static func pausedReviewPreservesAgenda() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech); tick(coordinator, &speech)
        coordinator.responseStarted(id: "before-review", scriptSpeechID: speech.last!.id)
        coordinator.pause()
        let cursor = coordinator.cursor, count = speech.count
        let result = await coordinator.navigate(page: 2)
        precondition(result.contains("true") && coordinator.currentSlide == 2 && coordinator.isPaused && !coordinator.running,
                     "an explicit agenda pause must still allow confirmed slide review")
        coordinator.responseFinished(id: "before-review", completed: true, hasAudio: true)
        coordinator.rendered(replyIDs: ["before-review"])
        clock.advance(20); tick(coordinator, &speech)
        precondition(coordinator.cursor == cursor && speech.count == count && fake.pages == [2],
                     "paused review must preserve the uncommitted agenda cursor and must not restart automatic speech")
        coordinator.takeOver()
        let denied = await coordinator.navigate(page: 1)
        precondition(denied.contains("false") && fake.pages == [2] && coordinator.currentSlide == 2,
                     "owner takeover must prohibit agent slide navigation, even when shared")
        coordinator.cancel()
        let cancelled = await coordinator.navigate(page: 1)
        precondition(cancelled.contains("false") && fake.pages == [2])
    }

    private static func concludeUsesClosingOnceAndKeepsSharedPage() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        await shared(coordinator, &speech); tick(coordinator, &speech)
        coordinator.responseStarted(id: "unfinished-agenda", scriptSpeechID: speech.last!.id)
        coordinator.pause()
        let review = await coordinator.navigate(page: 2)
        precondition(review.contains("true"))
        var interruptions = 0
        coordinator.onRequestInterruption = { interruptions += 1; coordinator.interrupted() }
        precondition(coordinator.conclude() && !coordinator.isPaused && coordinator.currentPhase == .closing)
        precondition(!coordinator.conclude() && interruptions == 1,
                     "duplicate conclude requests must not cancel or restart the configured closing")
        coordinator.responseFinished(id: "unfinished-agenda", completed: true, hasAudio: true)
        coordinator.rendered(replyIDs: ["unfinished-agenda"])
        clock.advance(0.3); tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.chunkID == "closing" && coordinator.currentSlide == 2 && fake.pages == [2],
                     "explicit wrap-up must speak only the configured closing and preserve the currently reviewed shared page")
        played(coordinator, id: "early-closing", script: speech.last)
        clock.advance(0.8); tick(coordinator, &speech); await settle(); tick(coordinator, &speech)
        precondition(coordinator.isFreeChat && coordinator.sharing && coordinator.currentSlide == 2)
        precondition(!coordinator.conclude())
        let count = speech.count
        tick(coordinator, &speech)
        precondition(speech.count == count && interruptions == 1)
    }

    private static func concludeBeforeSharingDoesNotOperateZoom() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture(opening: true))
        precondition(!coordinator.conclude(), "conclude cannot implicitly start a configured presentation")
        coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); coordinator.responseStarted(id: "old-opening", scriptSpeechID: speech.last!.id)
        precondition(coordinator.conclude())
        coordinator.responseFinished(id: "old-opening", completed: true, hasAudio: false)
        coordinator.rendered(replyIDs: ["old-opening"])
        clock.advance(0.3); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.chunkID == "closing" && fake.shares == 0 && fake.reads == 0 && fake.pages.isEmpty)
        played(coordinator, id: "unshared-closing", script: speech.last)
        clock.advance(0.8); tick(coordinator, &speech)
        precondition(coordinator.isFreeChat && !coordinator.sharing && coordinator.currentSlide == nil && !coordinator.conclude())
        coordinator.cancel(); precondition(!coordinator.conclude())
        try coordinator.configure(fixture()); coordinator.start(); coordinator.takeOver()
        precondition(!coordinator.conclude() && !coordinator.running,
                     "a listener wrap-up request cannot reclaim an owner's takeover")
    }

    private static func configureResetsOnlyForNewSessions() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture())
        precondition(fake.resets == 1 && fake.events.suffix(2) == ["cancel", "reset"],
                     "configure must invalidate/cancel the old driver before resetting its meeting binding")
        coordinator.start(); coordinator.pause(); coordinator.resume(); coordinator.interrupted()
        coordinator.takeOver(); coordinator.resume()
        precondition(fake.resets == 1, "pause, interruption, takeover and resume must retain the same meeting driver")
        try coordinator.configure(fixture())
        precondition(fake.resets == 2 && fake.shares == 0 && fake.reads == 0)

        var created = 0
        let native = PicoScriptedPresentation(driverFactory: { created += 1; return ZoomSlidesDriver() })
        precondition(created == 0, "constructing a coordinator must not prepare or inspect Zoom")
        try native.configure(fixture()); precondition(created == 1)
        native.start(); native.pause(); native.resume(); native.takeOver(); native.resume()
        precondition(created == 1)
        try native.configure(fixture()); precondition(created == 2, "each new meeting must receive a fresh real-driver instance")

        let first = ZoomSlidesDriver()
        var replacements = 0
        let injected = PicoScriptedPresentation(driver: first, driverFactory: { replacements += 1; return ZoomSlidesDriver() })
        try injected.configure(fixture()); precondition(replacements == 0)
        try injected.configure(fixture()); precondition(replacements == 1, "the explicit first test driver must not be reused for a second configured meeting")
    }

    private static func newConfigureRejectsOldMeetingResult() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        fake.deferShare = true
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); await settle()
        precondition(fake.shareContinuation != nil && fake.shares == 1)
        try coordinator.configure(fixture()); coordinator.start()
        tick(coordinator, &speech); await settle()
        var obsolete = fake.snapshot; obsolete.pid = 111; obsolete.currentSlide = 2
        fake.releaseShare(snapshot: obsolete); await settle()
        precondition(fake.resets == 2 && fake.shares == 2 && fake.pages.isEmpty && coordinator.sharing && coordinator.currentSlide == 1,
                     "the old meeting result cannot publish its page or issue a follow-up navigation through the new meeting's driver")
    }
    private static func explicitContinueReleasesOpeningWait() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture(opening: true)); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); played(coordinator, id: "greeting-before-recovery", script: speech.last)
        clock.advance(1); tick(coordinator, &speech)
        precondition(coordinator.waitingForReply && speech.count == 1)
        coordinator.interrupted(); coordinator.resume()
        clock.advance(1); tick(coordinator, &speech)
        precondition(coordinator.waitingForReply && speech.count == 1 && fake.shares == 0,
                     "reconnecting must not silently treat a greeting question as answered")
        coordinator.resume(continuePastReplyWait: true)
        clock.advance(1); tick(coordinator, &speech)
        precondition(!coordinator.waitingForReply && speech.count == 2 && speech.last?.chunkID == "share-intro" && fake.shares == 0,
                     "explicit continue must advance to the next chunk without waiting for an ordinary model acknowledgement")
    }
    private static func automaticResponseCannotBorrowScriptScope() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(fixture(opening: true)); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech)
        let original = speech.last!
        precondition(!coordinator.responseStarted(id: "wrong-scope", scriptSpeechID: UUID()))
        precondition(coordinator.responseStarted(id: "automatic-before-asr"), "nil provenance is an ordinary response even while script speech is pending")
        coordinator.guestTranscript(text: "你好，先聊一下。")
        coordinator.responseFinished(id: "automatic-before-asr", completed: true, hasAudio: true)
        coordinator.rendered(replyIDs: ["automatic-before-asr"])
        precondition(coordinator.cursor?.chunkIndex == 0,
                     "an automatic answer cannot commit a pending script chunk, including when the final input transcript arrives late")
        precondition(!coordinator.responseStarted(id: "stale-app", scriptSpeechID: original.id))
        coordinator.responseFinished(id: "stale-app", completed: true, hasAudio: true)
        coordinator.rendered(replyIDs: ["stale-app"])
        clock.advance(1.3); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.chunkID == original.chunkID && speech.last?.id != original.id)
        played(coordinator, id: "new-scoped-script", script: speech.last)
        precondition(coordinator.cursor?.chunkIndex == 1 && coordinator.waitingForReply)
    }
    private static func lateTranscriptPreservesOrdinaryPlayback() async throws {
        for transcriptAfterPlayback in [false, true] {
            let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
            let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
            try coordinator.configure(fixture(opening: true)); coordinator.start()
            var speech: [PicoScriptSpeech] = []
            tick(coordinator, &speech); played(coordinator, id: "opening-wait", script: speech.last)
            coordinator.interrupted()
            precondition(coordinator.responseStarted(id: "ordinary-early"))
            coordinator.responseFinished(id: "ordinary-early", completed: true, hasAudio: true)
            if transcriptAfterPlayback { coordinator.rendered(replyIDs: ["ordinary-early"]) }
            coordinator.guestTranscript(text: "今天挺好的。")
            clock.advance(2); tick(coordinator, &speech)
            if !transcriptAfterPlayback {
                precondition(speech.count == 1, "late ASR must preserve, rather than invalidate, the ordinary answer's remaining playback barrier")
                coordinator.rendered(replyIDs: ["ordinary-early"])
                clock.advance(1.3); tick(coordinator, &speech)
            }
            precondition(speech.count == 2 && speech.last?.chunkID == "share-intro" && !coordinator.waitingForReply,
                         "a late input transcript cannot create a second answer barrier after the actual ordinary answer has already played")
        }
    }
    private static func timedFixture(seconds: TimeInterval = 12, transition: String? = nil) -> PicoPresentationScript {
        var script = fixture(opening: true)
        script.opening[0].replyTimeoutSeconds = seconds
        script.opening[0].replyTimeoutTransition = transition
        return script
    }
    private static func replyTimeoutStartsAtPlaybackAndKeepsCursor() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(timedFixture()); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech)
        let greeting = speech.last!
        coordinator.responseStarted(id: "timed-opening", scriptSpeechID: greeting.id)
        coordinator.responseFinished(id: "timed-opening", completed: true, hasAudio: true)
        clock.advance(60); tick(coordinator, &speech)
        precondition(speech.count == 1 && !coordinator.waitingForReply,
                     "model completion cannot start the reply clock before actual playback drain")
        coordinator.rendered(replyIDs: ["timed-opening"])
        let cursor = coordinator.cursor
        clock.advance(11.9); tick(coordinator, &speech)
        precondition(speech.count == 1 && coordinator.waitingForReply)
        clock.advance(0.11); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.isReplyTimeoutTransition == true)
        precondition(speech.last?.text == "那我先往下介绍，你随时可以打断我。" && coordinator.cursor == cursor)
        let bridge = speech.last!
        coordinator.responseStarted(id: "silence-bridge", scriptSpeechID: bridge.id)
        coordinator.responseFinished(id: "silence-bridge", completed: true, hasAudio: true)
        clock.advance(30); tick(coordinator, &speech)
        precondition(speech.count == 2 && coordinator.waitingForReply && coordinator.cursor == cursor,
                     "the bridge must actually play before the wait is released")
        coordinator.rendered(replyIDs: ["silence-bridge"])
        precondition(!coordinator.waitingForReply && coordinator.cursor == cursor)
        clock.advance(0.8); tick(coordinator, &speech)
        precondition(speech.count == 3 && speech.last?.chunkID == "share-intro" && speech.last?.needsTransition == false,
                     "a completed silence bridge must resume exactly the next unplayed chunk, without a second bridge")
        clock.advance(30); tick(coordinator, &speech)
        precondition(speech.filter(\.isReplyTimeoutTransition).count == 1 && fake.shares == 0)
    }
    private static func replyTimeoutPausesForRemoteProcessing() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(timedFixture(seconds: 5, transition: "我先接着说。")); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); played(coordinator, id: "remote-wait", script: speech.last)
        clock.advance(2); tick(coordinator, &speech)
        coordinator.tick(canSpeak: true, remoteTurnPending: true) { speech.append($0); return true }
        clock.advance(40)
        coordinator.tick(canSpeak: true, remoteTurnPending: true) { speech.append($0); return true }
        precondition(speech.count == 1, "VAD/ASR/tool work must never expire a scripted silence wait")
        tick(coordinator, &speech)
        clock.advance(2); tick(coordinator, &speech)
        precondition(speech.count == 1)
        coordinator.tick(canSpeak: false) { speech.append($0); return true }
        clock.advance(40); coordinator.tick(canSpeak: false) { speech.append($0); return true }
        tick(coordinator, &speech)
        clock.advance(1.1); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.text == "我先接着说。",
                     "only eligible quiet time should count, and configured per-node transitions must be used")
    }
    private static func discardedVADRestoresReplyTimeout() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(timedFixture(seconds: 3)); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); played(coordinator, id: "noise-wait", script: speech.last)
        coordinator.interrupted()
        coordinator.tick(canSpeak: false, remoteTurnPending: true) { speech.append($0); return true }
        clock.advance(30)
        coordinator.tick(canSpeak: false, remoteTurnPending: true) { speech.append($0); return true }
        precondition(speech.count == 1)
        // Provider turns this VAD input into turn_invalid: no transcript and no answer.
        tick(coordinator, &speech)
        clock.advance(2.9); tick(coordinator, &speech)
        precondition(speech.count == 1 && coordinator.waitingForReply)
        clock.advance(0.2); tick(coordinator, &speech)
        precondition(speech.count == 2 && speech.last?.isReplyTimeoutTransition == true,
                     "a discarded VAD turn must return to the original reply wait, not stall in a nonexistent Q&A")
    }
    private static func replyTimeoutCannotOverrideHumanControl() async throws {
        for control in ["pause", "takeover", "cancel", "question"] {
            let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
            let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
            try coordinator.configure(timedFixture(seconds: 1)); coordinator.start()
            var speech: [PicoScriptSpeech] = []
            tick(coordinator, &speech); played(coordinator, id: "control-wait", script: speech.last)
            switch control {
            case "pause": coordinator.pause()
            case "takeover": coordinator.takeOver()
            case "cancel": coordinator.cancel()
            default:
                coordinator.holdForQuestion()
                played(coordinator, id: "permission-ack")
                coordinator.interrupted() // even if a subsequent VAD input is discarded
            }
            for _ in 0..<3 { clock.advance(120); tick(coordinator, &speech) }
            precondition(speech.count == 1 && fake.shares == 0,
                         "reply timeout cannot override \(control), including an unlimited question-permission hold")
        }
    }
    private static func realReplyAndInterruptedTimeoutKeepPlaybackBarriers() async throws {
        let fake = ScriptedSlidesFixture(), clock = ScriptedClock()
        let coordinator = PicoScriptedPresentation(operations: fake.operations, now: { clock.value })
        try coordinator.configure(timedFixture(seconds: 1)); coordinator.start()
        var speech: [PicoScriptSpeech] = []
        tick(coordinator, &speech); played(coordinator, id: "interrupt-wait", script: speech.last)
        clock.advance(1.1); tick(coordinator, &speech)
        let interruptedBridge = speech.last!
        precondition(interruptedBridge.isReplyTimeoutTransition)
        coordinator.responseStarted(id: "interrupted-bridge", scriptSpeechID: interruptedBridge.id)
        coordinator.interrupted(); coordinator.guestTranscript(text: "今天还好，你呢？")
        coordinator.responseFinished(id: "interrupted-bridge", completed: true, hasAudio: true)
        coordinator.rendered(replyIDs: ["interrupted-bridge"])
        precondition(coordinator.cursor?.chunkIndex == 1 && !coordinator.waitingForReply)
        coordinator.responseStarted(id: "actual-greeting-answer")
        coordinator.responseFinished(id: "actual-greeting-answer", completed: true, hasAudio: true)
        clock.advance(30); tick(coordinator, &speech)
        precondition(speech.count == 2 && coordinator.waitingForAnswerPlayback,
                     "real input and its ordinary answer must keep the actual-playback barrier instead of timing out")
        coordinator.rendered(replyIDs: ["actual-greeting-answer"])
        clock.advance(1.3); tick(coordinator, &speech)
        precondition(speech.count == 3 && speech.last?.chunkID == "share-intro")
        precondition(speech.filter(\.isReplyTimeoutTransition).count == 1)
    }
}

@MainActor private final class ScriptedClock {
    var value = Date(timeIntervalSince1970: 1_700_000_000)
    func advance(_ seconds: TimeInterval) { value.addTimeInterval(seconds) }
}
@MainActor private final class ScriptedSlidesFixture {
    var snapshot = ZoomSlidesDriver.Snapshot(pid: 9, meetingTitle: "Controlled test", documentTitle: "Fixture", currentSlide: 1, totalSlides: 2, sharing: .active)
    var shares = 0, reads = 0, cancellations = 0, resets = 0
    var events: [String] = []
    var pages: [Int] = []
    var deferShare = false
    var readFailures: [ZoomSlidesDriver.Failure] = []
    var shareContinuation: CheckedContinuation<ZoomSlidesDriver.Snapshot, Error>?
    var operations: PicoScriptedPresentation.Operations {
        .init(share: { [self] _ in
            shares += 1
            if deferShare {
                deferShare = false
                return try await withCheckedThrowingContinuation { shareContinuation = $0 }
            }
            return snapshot
        }, show: { [self] page in pages.append(page); snapshot.currentSlide = page; return snapshot },
        read: { [self] in
            reads += 1
            if !readFailures.isEmpty { throw readFailures.removeFirst() }
            return snapshot
        }, cancel: { [self] in cancellations += 1; events.append("cancel") },
        reset: { [self] in resets += 1; events.append("reset") })
    }
    func releaseShare(snapshot value: ZoomSlidesDriver.Snapshot? = nil) {
        let continuation = shareContinuation; shareContinuation = nil
        continuation?.resume(returning: value ?? snapshot)
    }
}

#if PICO_SCRIPTED_PRESENTATION_TEST_MAIN
@main struct ScriptedPresentationTestMain {
    @MainActor static func main() async throws { try await PicoScriptedPresentationTests.run() }
}
#endif
