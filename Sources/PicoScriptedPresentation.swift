import Combine
import Foundation

/// Coordinates the prepared agenda, confirmed Zoom pages and actually rendered speech.
/// Preparing a script has no external effect; only an explicit start can operate Zoom.
@MainActor final class PicoScriptedPresentation: ObservableObject {
    struct Operations {
        var share: (ZoomSlidesDriver.Target) async throws -> ZoomSlidesDriver.Snapshot
        var show: (Int) async throws -> ZoomSlidesDriver.Snapshot
        var read: () async throws -> ZoomSlidesDriver.Snapshot
        var cancel: () -> Void
        var reset: () -> Void = {}
    }
    /// Each operation snapshots its driver before awaiting. Replacing the holder therefore
    /// cannot redirect an old meeting's suspended task into the next meeting's driver.
    @MainActor private final class DriverHolder {
        private let factory: () -> ZoomSlidesDriver
        private var firstInjectedDriver: ZoomSlidesDriver?
        private(set) var driver: ZoomSlidesDriver?
        init(initial: ZoomSlidesDriver?, factory: @escaping () -> ZoomSlidesDriver) {
            self.firstInjectedDriver = initial; self.factory = factory
        }
        func reset() {
            driver = firstInjectedDriver ?? factory()
            firstInjectedDriver = nil
        }
        func current() -> ZoomSlidesDriver {
            if let driver { return driver }
            let prepared = factory(); driver = prepared; return prepared
        }
        func cancel() { driver?.cancel() }
    }
    @Published private(set) var status = "未加载演示脚本"
    @Published private(set) var isPaused = false
    @Published private(set) var currentSlide: Int?
    @Published private(set) var currentPhase: PicoScriptPhase?
    @Published private(set) var waitingForQuestion = false
    var onFailure: ((String) -> Void)?
    var onRequestInterruption: (() -> Void)?
    var isConfigured: Bool { flow != nil }
    var hasScript: Bool { isConfigured }
    var running: Bool { started && !manuallyPaused && flow?.isTakenOver != true && flow?.phase != .cancelled }
    private var canNavigate: Bool { started && flow?.isTakenOver != true && flow?.phase != .cancelled }
    var isFreeChat: Bool { flow?.phase == .freeChat }
    var waitingForReply: Bool { flow?.waitingForReply == true }
    var waitingForAnswerPlayback: Bool { flow?.answerID != nil || answerPlaybackAwaitingTranscript }
    var sharing: Bool { flow?.isSharing == true }
    var script: PicoPresentationScript? { flow?.script }
    var cursor: PicoScriptCursor? { flow?.cursor }

    private struct Playback {
        var speech: PicoScriptSpeech?
        var answer: UUID?
        var finished = false
        var rendered = false
    }
    private struct ReplyWaitClock {
        var chunkID: String
        var remaining: TimeInterval
        var lastTick: Date
        var counting: Bool
    }
    private let operations: Operations
    private let now: () -> Date
    private var flow: PicoPresentationFlow?
    private var started = false
    private var manuallyPaused = false
    private var awaitingGuestAnswer = false
    private var guestTranscriptSeen = false
    private var answerPlaybackAwaitingTranscript = false
    private var automaticResume = false
    private var scheduledSpeech: PicoScriptSpeech?
    private var speechSent = false
    private var playback: [String: Playback] = [:]
    private var epoch = UUID()
    private var operationID: UUID?
    private var operationTask: Task<Void, Never>?
    private var cancelledOperation: Task<Void, Never>?
    private var verifiedAt: Date?
    private var needsResynchronization = false
    private var nextSpeechAt = Date.distantPast
    private var lastFailure: String?
    private var replyWaitClock: ReplyWaitClock?

    convenience init(driver: ZoomSlidesDriver? = nil, driverFactory: @escaping () -> ZoomSlidesDriver = { ZoomSlidesDriver() }) {
        let holder = DriverHolder(initial: driver, factory: driverFactory)
        self.init(operations: Operations(share: { target in
            let current = holder.current(); return try await current.startSharing(target: target)
        }, show: { page in
            let current = holder.current(); return try await current.goToSlide(page)
        }, read: {
            let current = holder.current(); return try await current.readStatus()
        }, cancel: { holder.cancel() }, reset: { holder.reset() }))
    }
    init(operations: Operations, now: @escaping () -> Date = Date.init) {
        self.operations = operations; self.now = now
    }

    func configure(_ script: PicoPresentationScript?) throws {
        let prepared = try script.map { try PicoPresentationFlow(script: $0) }
        invalidateWork()
        operations.reset()
        flow = prepared; started = false; manuallyPaused = false; awaitingGuestAnswer = false
        automaticResume = false; waitingForQuestion = false
        verifiedAt = nil; needsResynchronization = false; lastFailure = nil
        status = prepared == nil ? "未加载演示脚本" : "脚本已准备，开始后再共享"
        publish()
    }
    func configure(script: PicoPresentationScript?) throws { try configure(script) }

    func start() {
        guard flow != nil, flow?.phase != .cancelled, !started else { return }
        started = true; manuallyPaused = false; automaticResume = false; lastFailure = nil
        nextSpeechAt = now(); status = "准备开场"; publish()
    }
    func pause() {
        guard started, flow?.phase != .cancelled else { return }
        manuallyPaused = true; automaticResume = false; awaitingGuestAnswer = false; waitingForQuestion = false
        invalidateWork(); flow?.interrupt(); status = "演示已暂停，共享画面保留"; publish()
        onRequestInterruption?()
    }
    /// The controller already owns the active farewell response. Freeze page/speech work
    /// without sending a second interruption back into that realtime tool transaction.
    func freezeForMeetingExit() {
        guard started, flow?.phase != .cancelled else { return }
        manuallyPaused = true; automaticResume = false; awaitingGuestAnswer = false; waitingForQuestion = false
        invalidateWork(); flow?.interrupt(); status = "会议收尾中，共享画面保留"; publish()
    }
    func takeOver() {
        guard flow != nil else { return }
        manuallyPaused = true; automaticResume = false; awaitingGuestAnswer = false; waitingForQuestion = false
        invalidateWork(); flow?.takeOver(); status = "你已接管，自动讲解和翻页已停止"; publish()
    }
    func resume(continuePastReplyWait: Bool = false) {
        guard started, flow?.phase != .cancelled else { return }
        invalidateWork(); flow?.interrupt(); _ = flow?.resume(continuePastReplyWait: continuePastReplyWait); manuallyPaused = false
        automaticResume = false; awaitingGuestAnswer = false; waitingForQuestion = false; lastFailure = nil
        // A restored connection/page must be read again before another line is spoken.
        verifiedAt = nil; needsResynchronization = true; nextSpeechAt = now().addingTimeInterval(0.6)
        status = waitingForReply ? "等待对方回答" : (isFreeChat ? "自由交流，共享画面保留" : "继续演示"); publish()
    }
    func cancel() {
        invalidateWork(); flow?.cancel(); started = false; manuallyPaused = true
        automaticResume = false; awaitingGuestAnswer = false; waitingForQuestion = false
        status = "演示已结束，共享画面未自动关闭"; publish()
    }
    /// Wrap up the prepared agenda once, without ending the call or changing the shared page.
    /// Repeated requests cannot replay a closing already in progress or completed.
    @discardableResult func conclude() -> Bool {
        guard started, flow?.isTakenOver != true, let phase = flow?.phase,
              phase != .cancelled, phase != .closing, phase != .freeChat else { return false }
        invalidateWork(); onRequestInterruption?()
        guard flow?.requestConclude() == true else { return false }
        manuallyPaused = false; automaticResume = false; awaitingGuestAnswer = false
        waitingForQuestion = false; lastFailure = nil
        verifiedAt = nil; needsResynchronization = false; nextSpeechAt = now().addingTimeInterval(0.2)
        status = "正在收尾，当前共享页面保留"; publish()
        return true
    }

    /// Called by the existing playback timer. Model completion is never sufficient to advance.
    func tick(canSpeak: Bool, remoteTurnPending: Bool = false, sendSpeech: (PicoScriptSpeech) -> Bool) {
        guard running, flow != nil else { return }
        // A VAD event can be discarded by the provider without producing a transcript or
        // answer. Once the realtime turn is completely idle, return to the original scripted
        // reply wait rather than inventing a permanent ordinary-answer barrier.
        if waitingForReply, awaitingGuestAnswer, !waitingForQuestion, !guestTranscriptSeen,
           !answerPlaybackAwaitingTranscript, flow?.answerID == nil, playback.isEmpty,
           canSpeak, !remoteTurnPending {
            awaitingGuestAnswer = false; automaticResume = false
            status = "等待对方回答"
        }
        let silenceElapsed = advanceReplyWaitClock(eligible: canSpeak && !remoteTurnPending &&
            !awaitingGuestAnswer && !waitingForQuestion && !answerPlaybackAwaitingTranscript &&
            flow?.answerID == nil && playback.isEmpty && flow?.isPaused != true)
        guard operationID == nil else { return }
        if sharing, verifiedAt == nil || now().timeIntervalSince(verifiedAt!) >= 1.5 {
            inspectSharing(); return
        }
        guard canSpeak, !remoteTurnPending, !awaitingGuestAnswer, !manuallyPaused,
              flow?.isPaused != true, now() >= nextSpeechAt else { publish(); return }
        if let speech = scheduledSpeech {
            if !speechSent { speechSent = sendSpeech(speech) }
            return
        }
        if silenceElapsed, let speech = flow?.requestReplyTimeoutTransition() {
            replyWaitClock = nil; scheduledSpeech = speech; speechSent = false
            status = "自然接回演示"; speechSent = sendSpeech(speech); publish(); return
        }
        guard let action = flow?.nextAction() else { publish(); return }
        switch action {
        case .speak(let speech):
            scheduledSpeech = speech; speechSent = false
            status = speech.slideNumber.map { "正在讲解第 \($0) 页" } ?? (speech.phase == .closing ? "演示收尾" : "正在开场")
            speechSent = sendSpeech(speech)
        case .requestShare(let page): beginPageOperation(page: page, sharing: true)
        case .showSlide(let page): beginPageOperation(page: page, sharing: false)
        case .waitForReply: status = "等待对方回答"
        case .finished:
            automaticResume = false; status = sharing ? "自由交流，保留当前共享页面" : "自由交流"
        }
        publish()
    }

    @discardableResult func responseStarted(id: String, scriptSpeechID: UUID? = nil) -> Bool {
        guard running, !id.isEmpty, playback[id] == nil else { return false }
        // A tool-only provider response may precede the actual spoken response. Keep the
        // same pending agenda token only across explicitly tagged responses from that request.
        if let scriptSpeechID {
            guard let speech = scheduledSpeech ?? flow?.pending,
                  speech.id == scriptSpeechID, (speechSent || scheduledSpeech == nil),
                  !awaitingGuestAnswer, speech.generation == flow?.generation else { return false }
            playback[id] = Playback(speech: speech)
            scheduledSpeech = nil; speechSent = false
        } else {
            // A server-generated conversational response can arrive before the final input
            // transcript. It must never borrow the pending script token or advance its cursor.
            if scheduledSpeech != nil || flow?.pending != nil { interrupted() }
            // Function-call-only responses do not finish in the realtime client; the eventual
            // spoken answer gets its own response ID and the same ordinary-answer barrier.
            let answer = flow?.answerID ?? flow?.beginAnswer()
            playback[id] = Playback(answer: answer)
        }
        return true
    }
    /// Production supplies hasAudio from its accepted output buffer IDs. Nil preserves older
    /// diagnostic callers which only supply the separate rendered callback.
    func responseFinished(id: String, completed: Bool, hasAudio: Bool? = nil) {
        guard var item = playback[id] else { return }
        guard completed else {
            playback.removeValue(forKey: id)
            if item.speech != nil { interrupted() }
            return
        }
        guard hasAudio != false else {
            fail("语音回复已结束，但没有收到可播放的音频。演示已暂停，当前段落未记为完成。")
            return
        }
        item.finished = true; playback[id] = item; commitPlayback(id)
    }
    func rendered(replyIDs: Set<String>) {
        for id in replyIDs {
            guard var item = playback[id] else { continue }
            item.rendered = true; playback[id] = item; commitPlayback(id)
        }
    }

    /// Barge-in invalidates pending page operations and late audio response IDs immediately.
    /// A normal answer may release this hold only after that answer has actually played.
    func interrupted() {
        guard started, flow?.phase != .cancelled else { return }
        let allowResume = !manuallyPaused && flow?.isTakenOver != true && !isFreeChat
        invalidateWork(); flow?.interrupt()
        automaticResume = allowResume; awaitingGuestAnswer = allowResume
        status = manuallyPaused ? "演示已暂停，共享画面保留" : "正在听对方说话"
        publish()
    }
    func guestTranscript(text: String) {
        guard running, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        waitingForQuestion = false
        if scheduledSpeech != nil || flow?.pending != nil { interrupted() }
        guestTranscriptSeen = true
        replyWaitClock = nil
        flow?.guestReplyReceived()
        if answerPlaybackAwaitingTranscript {
            answerPlaybackAwaitingTranscript = false
            finishOrdinaryAnswer(); publish(); return
        }
        if !isFreeChat {
            automaticResume = !manuallyPaused
            awaitingGuestAnswer = true
            if flow?.answerID == nil { _ = flow?.beginAnswer() }
        }
        status = "正在回应对方"; publish()
    }

    /// A polite request to ask something is not the actual question. A spoken acknowledgement
    /// may complete, but only a subsequent substantive guestTranscript releases this hold.
    func holdForQuestion() {
        guard running, !manuallyPaused else { return }
        if scheduledSpeech != nil || flow?.pending != nil {
            interrupted(); onRequestInterruption?()
        }
        waitingForQuestion = true; automaticResume = !isFreeChat; awaitingGuestAnswer = true
        replyWaitClock = nil
        status = "等对方提出问题"; publish()
    }

    /// A review request only changes the displayed page. It never advances or restarts the
    /// prepared agenda, including after the last page has entered free conversation.
    func navigate(page: Int) async -> String {
        guard canNavigate, sharing, let count = flow?.script.slides.count, (1...count).contains(page) else {
            return result(false, message: "当前不能切换到这一页，请确认正在共享，且页码有效。")
        }
        guard operationID == nil || operationTask != nil else { return result(false, message: "另一次翻页尚未确认，请稍后再试。") }
        let existing = operationTask ?? cancelledOperation
        invalidatePageWork()
        let awaitingEpoch = epoch
        await existing?.value
        guard awaitingEpoch == epoch, canNavigate, sharing else { return result(false, message: "演示状态已变化，未继续翻页。") }
        cancelledOperation = nil
        do { _ = try flow?.jumpToSlide(page) }
        catch { return result(false, message: error.localizedDescription) }
        scheduledSpeech = nil; speechSent = false
        // Keep an ordinary answer in progress: its playback, not this tool result, resumes
        // the agenda after the requested page has been discussed.
        if !isFreeChat { automaticResume = !manuallyPaused; awaitingGuestAnswer = true }
        let token = epoch, identifier = UUID(); operationID = identifier
        status = "正在显示第 \(page) 页"; publish()
        do {
            let snapshot = try await operations.show(page)
            guard token == epoch, operationID == identifier, canNavigate else { return result(false, message: "翻页已取消。") }
            try validate(snapshot, page: page)
            let generation = flow!.generation
            guard flow?.slideShown(page: page, generation: generation) == true else { throw ZoomSlidesDriver.Failure.cancelled }
            operationID = nil; verifiedAt = now(); status = "正在显示第 \(page) 页"; publish()
            return result(true, message: "已确认显示第 \(page) 页。只回答当前问题，不重讲整页，也不自行推进主讲进度。", page: page)
        } catch {
            guard token == epoch, operationID == identifier else { return result(false, message: "翻页已取消。") }
            operationID = nil; fail(error.localizedDescription)
            return result(false, message: error.localizedDescription)
        }
    }

    private func commitPlayback(_ id: String) {
        guard let item = playback[id], item.finished, item.rendered, running else { return }
        playback.removeValue(forKey: id)
        if let speech = item.speech {
            guard flow?.playbackCompleted(id: speech.id, generation: speech.generation) == true else { return }
            playback = playback.filter { $0.value.speech?.id != speech.id }
            if let wait = flow?.replyWait, let timeout = wait.timeoutSeconds {
                replyWaitClock = ReplyWaitClock(chunkID: wait.chunkID, remaining: timeout,
                    lastTick: now(), counting: true)
            } else { replyWaitClock = nil }
            nextSpeechAt = now().addingTimeInterval(0.7)
            status = flow?.waitingForReply == true ? "等待对方回答" : "继续演示"
        } else if let answer = item.answer {
            guard flow?.answerPlaybackCompleted(id: answer) == true else { return }
            playback = playback.filter { $0.value.answer != answer }
            if waitingForQuestion {
                awaitingGuestAnswer = true; status = "等对方提出问题"; publish(); return
            }
            if awaitingGuestAnswer && !guestTranscriptSeen && !isFreeChat {
                answerPlaybackAwaitingTranscript = true; status = "等待对方发言识别完成"; publish(); return
            }
            finishOrdinaryAnswer()
        }
        publish()
    }
    private func finishOrdinaryAnswer() {
        awaitingGuestAnswer = false
        if automaticResume && !manuallyPaused && flow?.isTakenOver != true {
            _ = flow?.resume(); automaticResume = false
            nextSpeechAt = now().addingTimeInterval(1.2)
            status = "回答完毕，准备自然接回演示"
        } else { status = isFreeChat ? "自由交流，保留当前共享页面" : "演示已暂停，共享画面保留" }
    }
    private func beginPageOperation(page: Int, sharing shouldShare: Bool) {
        guard let script = flow?.script, let url = try? script.validatedDeckURL() else { fail("演示文稿配置无效。"); return }
        let token = epoch, generation = flow!.generation, identifier = UUID()
        let preceding = cancelledOperation; cancelledOperation = nil
        operationID = identifier; status = shouldShare ? "正在共享演示文稿" : "正在显示第 \(page) 页"
        let target = ZoomSlidesDriver.Target(url: url, title: script.title, totalSlides: script.slides.count)
        operationTask = Task { [weak self] in
            guard let self else { return }
            await preceding?.value
            guard token == self.epoch, self.operationID == identifier, self.running else { return }
            do {
                var snapshot = try await (shouldShare ? self.operations.share(target) : self.operations.show(page))
                guard token == self.epoch, self.operationID == identifier, self.running else { return }
                // Sharing is idempotent: an already shared deck may still be on its last page.
                // Restore the explicitly requested first page and confirm it before narration.
                if shouldShare, snapshot.currentSlide != page {
                    try self.validate(snapshot, page: nil)
                    snapshot = try await self.operations.show(page)
                }
                guard token == self.epoch, self.operationID == identifier, self.running else { return }
                try self.validate(snapshot, page: page)
                let accepted = shouldShare ? self.flow?.shareConfirmed(page: page, generation: generation) : self.flow?.slideShown(page: page, generation: generation)
                guard accepted == true else { throw ZoomSlidesDriver.Failure.cancelled }
                self.operationID = nil; self.operationTask = nil; self.verifiedAt = self.now(); self.needsResynchronization = false
                self.status = "已确认第 \(page) 页，准备讲解"; self.publish()
            } catch {
                guard token == self.epoch, self.operationID == identifier else { return }
                self.operationID = nil; self.operationTask = nil; self.fail(error.localizedDescription)
            }
        }
    }
    private func inspectSharing() {
        let token = epoch, identifier = UUID(), expectedPage = needsResynchronization ? nil : flow?.visibleSlide
        let preceding = cancelledOperation; cancelledOperation = nil
        operationID = identifier
        operationTask = Task { [weak self] in
            guard let self else { return }
            await preceding?.value
            guard token == self.epoch, self.operationID == identifier, self.running else { return }
            do {
                let snapshot = try await self.operations.read()
                guard token == self.epoch, self.operationID == identifier, self.running else { return }
                try self.validate(snapshot, page: expectedPage)
                if self.needsResynchronization, let actual = snapshot.currentSlide, actual != self.flow?.visibleSlide {
                    _ = try self.flow?.jumpToSlide(actual)
                    let generation = self.flow!.generation
                    guard self.flow?.slideShown(page: actual, generation: generation) == true else { throw ZoomSlidesDriver.Failure.cancelled }
                    _ = self.flow?.resume()
                }
                self.needsResynchronization = false
                self.operationID = nil; self.operationTask = nil; self.verifiedAt = self.now()
                self.publish()
            } catch {
                guard token == self.epoch, self.operationID == identifier else { return }
                self.operationID = nil; self.operationTask = nil
                if let failure = error as? ZoomSlidesDriver.Failure, failure == .busy {
                    self.verifiedAt = nil; return // A cancelled previous UI action is still draining.
                }
                self.fail(error.localizedDescription)
            }
        }
    }
    private func validate(_ snapshot: ZoomSlidesDriver.Snapshot, page: Int?) throws {
        guard snapshot.sharing == .active else { throw ZoomSlidesDriver.Failure.unavailable("无法确认 Slides 仍在共享，已暂停讲解和翻页。") }
        guard let current = snapshot.currentSlide, current >= 1,
              current <= (flow?.script.slides.count ?? 0) else { throw ZoomSlidesDriver.Failure.unavailable("无法确认当前幻灯片页码，已暂停讲解。") }
        if let page, current != page { throw ZoomSlidesDriver.Failure.unavailable("实际页面与讲解进度不一致，已暂停，请确认后继续。") }
        if let total = snapshot.totalSlides, total != flow?.script.slides.count { throw ZoomSlidesDriver.Failure.documentMismatch }
    }
    private func fail(_ message: String) {
        guard started else { return }
        manuallyPaused = true; automaticResume = false; awaitingGuestAnswer = false; waitingForQuestion = false
        invalidateWork(); flow?.interrupt(); status = message; publish()
        guard lastFailure != message else { return }
        lastFailure = message; onFailure?(message)
    }
    private func invalidatePageWork() {
        epoch = UUID(); operations.cancel()
        if let operationTask { cancelledOperation = operationTask; operationTask.cancel() }
        operationID = nil; operationTask = nil
    }
    private func invalidateWork() {
        invalidatePageWork(); playback.removeAll(); scheduledSpeech = nil; speechSent = false
        guestTranscriptSeen = false; answerPlaybackAwaitingTranscript = false
        replyWaitClock = nil
    }
    private func advanceReplyWaitClock(eligible: Bool) -> Bool {
        guard waitingForReply, let wait = flow?.replyWait, let timeout = wait.timeoutSeconds,
              flow?.pending == nil, scheduledSpeech == nil else { replyWaitClock = nil; return false }
        let instant = now()
        var clock = replyWaitClock.flatMap { $0.chunkID == wait.chunkID ? $0 : nil } ??
            ReplyWaitClock(chunkID: wait.chunkID, remaining: timeout, lastTick: instant, counting: false)
        if clock.counting && eligible {
            clock.remaining -= max(0, instant.timeIntervalSince(clock.lastTick))
        }
        clock.lastTick = instant; clock.counting = eligible
        replyWaitClock = clock
        return eligible && clock.remaining <= 0
    }
    private func publish() {
        isPaused = manuallyPaused || waitingForQuestion || flow?.isPaused == true || flow?.isTakenOver == true
        currentSlide = flow?.visibleSlide; currentPhase = flow?.phase
    }
    private func result(_ ok: Bool, message: String, page: Int? = nil) -> String {
        var value: [String: Any] = ["ok": ok, "message": message]
        if let page { value["page"] = page }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "{\"ok\":false}" }
        return text
    }
}
