import SwiftUI
import AppKit
import AVFoundation

struct PicoMeetingTurn: Codable, Identifiable {
    var id: String
    var role: String
    var text: String
    var time: Double
    var delivery: String? = nil // generated, locally_rendered, or interrupted; never proves remote audibility.
}
struct PicoMeetingRecord: Codable {
    var id = UUID()
    var started = Date()
    var ended: Date?
    var title: String
    var turns: [PicoMeetingTurn] = []
    var preparation: PicoMeetingPreparation?
    var meetingID: UUID?
}

@MainActor final class PicoMeetingController: ObservableObject {
    @Published var status = "Ready for a relaxed 1-on-1"
    let preparation: PicoPreparationStore
    var brief: String { get { preparation.draft.background } set { preparation.draft.background = newValue } }
    private var openingPending = false
    @Published private(set) var presentationStatus = ""
    @Published private(set) var presentationPaused = false
    @Published private(set) var presentationConcluded = false
    private var sectionIndex = 0
    private var sectionRequested = false
    private var sectionResponse: String?
    private var completedSectionWaitingForPlayback = false
    private var nextSectionAt: Date?
    private var flowTimer: Timer?
    private var recovery: Task<Void, Never>?
    private var recoveryAttempts = 0
    private var connectionEpoch = UUID()
    private var allowAgent = false
    private var awaitingQuestion = false
    private var sectionWasInterrupted = false
    private var transitionPending = false
    private var lastDiscussion = ""
    private var queuedReplyIDs = Set<String>()
    private var finishedReplyIDs = Set<String>()
    private var renderedReplyIDs = Set<String>()
    private var interruptedReplyIDs = Set<String>()
    private var rememberedReplyIDs = Set<String>()
    private var renderedReplyTexts: [String] = []
    private var humanHasControl = false
    private var savingRecord = false
    private var memoryPreparation: Task<Void, Never>?
    private var lastRemoteAudio = Date.distantPast
    private var traceEvents: [String] = []
    @Published var memoryEnabled = UserDefaults.standard.object(forKey: PicoMemoryStore.enabledPreference) == nil || UserDefaults.standard.bool(forKey: PicoMemoryStore.enabledPreference) {
        didSet { UserDefaults.standard.set(memoryEnabled, forKey: PicoMemoryStore.enabledPreference) }
    }
    @Published private(set) var memoryStatus = ""
    @Published var devices = PicoAudioDevice.all()
    @Published var microphoneID: AudioDeviceID = 0
    @Published var virtualID: AudioDeviceID = 0
    @Published var routeConfirmed = false
    @Published private(set) var active = false
    @Published private(set) var connecting = false
    @Published private(set) var agentSpeaking = false
    @Published private(set) var turns: [PicoMeetingTurn] = []
    private let audio = PicoMeetingAudio()
    private let realtime = PicoRealtime()
    private var capture: (any MeetingAudioCapturing)?
    private var record: PicoMeetingRecord?
    private var window: NSWindow?
    private var monitor: Any?, localMonitor: Any?
    private var timer: Timer?
    private var observing = false
    private var meetingMissingSince: Date?
    private var generation = UUID()
    private var startup: Task<Void, Never>?
    let dataDir: URL
    private let handoff: (PicoMeetingRecord) -> Void
    private let onOwnerSpeechChanged: ((Bool) -> Void)?
    private let connectMeeting: ((MeetingObservation, String) async throws -> (UUID, Date))?
    private let makeCapture: (() -> any MeetingAudioCapturing)?
    init(dataDir: URL, connectMeeting: ((MeetingObservation, String) async throws -> (UUID, Date))? = nil, makeCapture: (() -> any MeetingAudioCapturing)? = nil, onOwnerSpeechChanged: ((Bool) -> Void)? = nil, handoff: @escaping (PicoMeetingRecord) -> Void) {
        self.dataDir = dataDir; self.handoff = handoff; self.connectMeeting = connectMeeting; self.makeCapture = makeCapture; self.onOwnerSpeechChanged = onOwnerSpeechChanged
        self.preparation = PicoPreparationStore(directory: dataDir)
        refreshDevices()
        audio.onError = { [weak self] text in Task { @MainActor in self?.pauseForFailure(text) } }
        realtime.onError = { [weak self] text in self?.pauseForFailure(text) }
        realtime.onRecoverableError = { [weak self] text in self?.recoverConnection(text) }
        realtime.onWarning = { [weak self] text in self?.status = text }
        realtime.onDiagnosticEvent = { [weak self] text in self?.trace(text) }
        realtime.onResponseStarted = { [weak self] id in
            guard let self else { return }
            self.nextSectionAt = nil
            if self.sectionRequested || self.sectionResponse != nil { self.sectionResponse = id; self.sectionRequested = false }
            self.status = "Pico 正在组织回复"
        }
        realtime.onResponseFinished = { [weak self] id, completed in
            guard let self else { return }
            if completed { self.recoveryAttempts = 0 }
            if completed { self.finishedReplyIDs.insert(id) }
            if self.sectionResponse == id {
                self.completedSectionWaitingForPlayback = completed && self.queuedReplyIDs.contains(id)
                if !self.completedSectionWaitingForPlayback { self.sectionResponse = nil }
            }
            // Generation completion is not playback completion. The render-drain tick owns pacing.
            if !self.queuedReplyIDs.contains(id), !self.presentationPaused { self.nextSectionAt = Date().addingTimeInterval(1.5) }
        }
        realtime.onReady = { [weak self] in
            guard let self, self.active, self.allowAgent else { return }
            self.connecting = false; self.audio.gate.switchTo(.agent); self.agentSpeaking = true; self.humanHasControl = false; self.onOwnerSpeechChanged?(false)
            self.status = "Pico is listening · You can take over anytime"
            self.trace("connection_ready")
            if self.openingPending {
                self.openingPending = false
                self.nextSectionAt = Date()
            } else if self.preparation.draft.present && !self.presentationPaused {
                self.nextSectionAt = Date().addingTimeInterval(4)
            }
        }
        realtime.onAudio = { [weak self] bytes, id in
            guard let self, self.active, self.agentSpeaking else { return }
            guard !self.interruptedReplyIDs.contains(id) else { return }
            if !bytes.isEmpty { self.queuedReplyIDs.insert(id) }
            let token = self.audio.gate.token()
            if !self.audio.appendAgent(bytes, token: token) { self.pauseForFailure("语音缓冲超过 120 秒，已停止输出；本段未标为完成") }
        }
        realtime.onInterruption = { [weak self] in
            guard let self else { return }
            self.interruptPlayback()
            self.status = "对方正在说话 · Pico 已停止播放"
            self.trace("barge_in_audio_flushed")
        }
        realtime.onMemorySearch = { [weak self] query, result in
            guard let self, self.active else { return }
            self.memoryStatus = result.error == nil ? "Telos 记忆：检索到 \(result.notes.count) 条相关背景" : "Telos 记忆暂时不可用"
            self.addTurn(role: "memory", text: "Memory search: " + query + "; note IDs: " + result.notes.map(\.id).joined(separator: ", ") + (result.error.map { "; " + $0 } ?? ""), id: UUID().uuidString)
        }
        realtime.onTranscript = { [weak self] role, text, id in
            guard let self else { return }
            if role == "other" { self.handlePresentationInput(text) }
            self.addTurn(role: role, text: text, id: id)
        }
    }
    func refreshDevices() {
        devices = PicoAudioDevice.all()
        if !devices.contains(where: { $0.id == microphoneID }) { microphoneID = devices.first(where: { $0.physical })?.id ?? 0 }
        if !devices.contains(where: { $0.id == virtualID }) { virtualID = devices.first(where: { $0.virtual && $0.input && $0.output })?.id ?? 0 }
    }
    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Pico · Meeting companion"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PicoMeetingView(controller: self))
            window.level = .floating; window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        installHotkey()
    }
    private func installHotkey() {
        guard monitor == nil else { return }
        func matches(_ event: NSEvent) -> Bool { event.keyCode == 49 && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in if matches(event) && !event.isARepeat { Task { @MainActor in self?.takeOver() } } }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in if matches(event) && !event.isARepeat { self?.takeOver(); return nil }; return event }
    }
    func start() {
        guard startup == nil, !active, !connecting, routeConfirmed, #available(macOS 26, *) else { return }
        guard !preparation.draft.present || (!preparation.draft.sections.isEmpty && preparation.draft.sections.count <= 12 && preparation.draft.sections.allSatisfy { $0.count <= 500 }) else { status = "请填写讲解提纲：1–12 段，每段不超过 500 字符"; return }
        guard !preparation.busy else { status = "请等待材料解析完成"; return }
        guard preparation.draft.background.count <= 4000, preparation.draft.goal.count <= 2000 else { status = "背景最多 4000 字符，目标最多 2000 字符，请精简后开始"; return }
        refreshDevices()
        guard let virtual = devices.first(where: { $0.id == virtualID && $0.virtual }), let mic = devices.first(where: { $0.id == microphoneID && $0.physical }) else { status = "Install BlackHole 2ch, then refresh audio devices."; return }
        generation = UUID(); let token = generation; connecting = true; status = "Checking the current Zoom meeting…"
        startup = Task { [self] in
            defer { startup = nil }
            let observation = await Task.detached { ZoomMeetingAdapter().observe() }.value
            guard generation == token, !Task.isCancelled else { return }
            guard observation.signal == .joined else { connecting = false; status = "Join your intended Zoom meeting first. Pico will not join a meeting for you."; return }
            guard await AVCaptureDevice.requestAccess(for: .audio), CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { connecting = false; status = "Allow microphone and Screen & System Audio Recording in macOS settings."; return }
            guard generation == token, !Task.isCancelled else { return }
            do {
                onOwnerSpeechChanged?(false)
                let binding = try await connectMeeting?(observation, mic.uid)
                guard generation == token, !Task.isCancelled else { return }
                try audio.start(virtual: virtual, mic: mic)
                let recorder: any MeetingAudioCapturing
                if let makeCapture { recorder = makeCapture() }
                else { let standalone = MeetingAudioCapture(); standalone.captureLocalMicrophone = false; recorder = standalone }
                let converter = MeetingPCMConverter()
                recorder.onBuffer = { [weak self] buffer, source, _ in
                    guard source == .others else { return }
                    do {
                        let pcm = try converter.convert(buffer)
                        Task { @MainActor in guard let self, self.generation == token, self.agentSpeaking else { return }; self.lastRemoteAudio = Date(); self.realtime.append(pcm) }
                    } catch { Task { @MainActor in self?.pauseForFailure("无法读取 Zoom 音频") } }
                }
                recorder.onError = { [weak self] text in Task { @MainActor in self?.pauseForFailure(text) } }
                capture = recorder
                try await recorder.start(pid: observation.pid, elapsed: binding.map { Date().timeIntervalSince($0.1) } ?? 0)
                guard generation == token, !Task.isCancelled else { await recorder.stop(); audio.stop(); return }
                record = PicoMeetingRecord(started: binding?.1 ?? Date(), title: observation.title, preparation: preparation.draft, meetingID: binding?.0); turns = []; active = true; meetingMissingSince = nil
                addTurn(role: "system", text: "Pico session started. AI-generated speech is not an owner commitment.", id: UUID().uuidString)
                sectionIndex = 0; sectionRequested = false; sectionResponse = nil; completedSectionWaitingForPlayback = false
                presentationPaused = false; presentationConcluded = false; awaitingQuestion = false; sectionWasInterrupted = false; transitionPending = false; lastDiscussion = ""
                queuedReplyIDs.removeAll(); finishedReplyIDs.removeAll(); renderedReplyIDs.removeAll(); interruptedReplyIDs.removeAll(); rememberedReplyIDs.removeAll(); renderedReplyTexts.removeAll()
                recoveryAttempts = 0; allowAgent = true; humanHasControl = false
                openingPending = preparation.draft.present
                flowTimer?.invalidate()
                flowTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.advancePresentation() } }
                startConversation()
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkDevices() } }
            } catch { connecting = false; onOwnerSpeechChanged?(true); audio.stop(); await capture?.stop(); capture = nil; status = error.localizedDescription }
        }
    }
    private func checkDevices() {
        guard active else { return }
        let present = PicoAudioDevice.all()
        if allowAgent && (!audio.running || !present.contains(where: { $0.id == virtualID }) || !present.contains(where: { $0.id == microphoneID })) { pauseForFailure("音频设备已断开，请重新选择设备后继续"); return }
        if connectMeeting != nil { return } // Canonical manager owns Zoom detection and ending.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").isEmpty { finish(); return }
        guard !observing else { return }
        observing = true
        let token = generation
        Task {
            let observation = await Task.detached(priority: .utility) { ZoomMeetingAdapter().observe() }.value
            observing = false
            guard active, generation == token else { return }
            if observation.signal == .joined { meetingMissingSince = nil }
            else {
                if meetingMissingSince == nil { meetingMissingSince = Date() }
                let elapsed = Date().timeIntervalSince(meetingMissingSince!)
                if observation.signal != .unknown && elapsed >= 8 { finish() }
                else if elapsed >= 60 && agentSpeaking && Date().timeIntervalSince(lastRemoteAudio) > 15 { pauseForFailure("无法确认 Zoom 音频状态，已暂停；请检查 Zoom 后继续") }
            }
        }
    }
    private func startConversation() {
        guard active else { return }
        connectionEpoch = UUID()
        connecting = true; status = "正在连接百炼…"
        let history = turns.filter { ["other", "pico", "pico_interrupted"].contains($0.role) }.map {
            let label = $0.role == "other" ? "participant" : ($0.delivery == "locally_rendered" ? "Pico locally rendered reply" : "Pico generated or interrupted reply; playback not verified")
            return "\(label): \($0.text)"
        }.joined(separator: "\n")
        memoryStatus = memoryEnabled ? "会按问题检索 Telos 记忆" : "本场不使用 Telos 记忆"
        let directory = dataDir
        realtime.presentationControl = preparation.draft.present ? { [weak self] action in
            guard let self, self.active, self.allowAgent, self.preparation.draft.present else { return "{\"applied\":false,\"reason\":\"Presentation is not active.\"}" }
            return self.applyPresentationControl(action)
        } : nil
        realtime.memoryLookup = memoryEnabled ? { query in
            let excluded = Set(UserDefaults.standard.stringArray(forKey: PicoMemoryStore.excludedPreference) ?? [])
            return await Task.detached(priority: .userInitiated) { PicoMemoryStore.search(query: query, directory: directory, excluded: excluded) }.value
        } : nil
        let prepared = preparation.draft.context, goal = preparation.draft.goal, brief = self.brief
        let epoch = connectionEpoch, useMemory = memoryEnabled
        memoryPreparation?.cancel()
        memoryPreparation = Task { [weak self] in
            let background: PicoMemoryResult
            if useMemory {
                let excluded = Set(UserDefaults.standard.stringArray(forKey: PicoMemoryStore.excludedPreference) ?? [])
                background = await Task.detached(priority: .userInitiated) { PicoMemoryStore.search(query: "身份 工作 项目 兴趣 计划 想法 " + goal, directory: directory, excluded: excluded) }.value
            } else { background = PicoMemoryResult(notes: []) }
            guard let self, !Task.isCancelled, self.active, self.allowAgent, self.connectionEpoch == epoch else { return }
            self.realtime.preparationContext = prepared + (useMemory ? "\nAPPROVED RELEVANT OWNER BACKGROUND (dated evidence, not commitments):\n" + background.json : "")
            self.memoryStatus = useMemory ? "会前已读取 \(background.notes.count) 条相关背景；其他问题可继续检索" : "本场不使用 Telos 记忆"
            if useMemory { self.addTurn(role: "memory", text: "会前相关记忆 ID：" + background.notes.map(\.id).joined(separator: ", "), id: UUID().uuidString) }
            self.realtime.start(brief: brief, history: history)
        }
    }
    func resume() {
        guard active, !agentSpeaking, !connecting else { return }
        allowAgent = true; humanHasControl = false; audio.gate.switchTo(.silence); onOwnerSpeechChanged?(false)
        transitionPending = true; recoveryAttempts = 0; recovery?.cancel(); recovery = nil
        startConversation()
    }
    func takeOver(reason: String = "你已接管 · 真实麦克风已接通") {
        let wasRunning = allowAgent || connecting || agentSpeaking || (active && !humanHasControl)
        stopAgent(reason)
        if active && wasRunning { addTurn(role: "system", text: "用户主动接管。Pico 播放和待播音频已停止；后续用户语音不计入代理记录。", id: UUID().uuidString) }
    }
    private func stopAgent(_ reason: String, handToHuman: Bool = true) {
        // First and synchronous: never let cancellation/reconnect race with human takeover.
        interruptPlayback()
        humanHasControl = handToHuman; audio.gate.switchTo(handToHuman ? .human : .silence); onOwnerSpeechChanged?(handToHuman)
        memoryPreparation?.cancel(); memoryPreparation = nil
        allowAgent = false; connectionEpoch = UUID(); recovery?.cancel(); recovery = nil
        agentSpeaking = false; connecting = false; realtime.stop()
        nextSectionAt = nil; sectionRequested = false; sectionResponse = nil; completedSectionWaitingForPlayback = false
        if !active { generation = UUID(); startup?.cancel() }
        status = reason
    }
    private func pauseForFailure(_ reason: String) {
        guard allowAgent || agentSpeaking || connecting else { return }
        stopAgent(reason, handToHuman: false)
        if active { addTurn(role: "system", text: "Pico 因故障暂停：" + reason + "。不是用户接管。", id: UUID().uuidString) }
        trace("paused reason=" + reason)
    }
    func pauseForMeetingUncertainty() { pauseForFailure("暂时无法确认 Zoom 会议，Pico 已暂停输出；确认会议后由你选择继续或接管") }
    private func recoverConnection(_ reason: String) {
        guard active, allowAgent else { return }
        if reason.contains("idle_timeout") { recoveryAttempts = 0 } // Provider idle expiry is a renewal, not a failed network retry.
        guard recoveryAttempts < 3 else { pauseForFailure("重连 3 次仍失败：" + reason); return }
        interruptPlayback()
        audio.gate.switchTo(.silence); onOwnerSpeechChanged?(false); humanHasControl = false; agentSpeaking = false; connecting = true
        sectionRequested = false; sectionResponse = nil; completedSectionWaitingForPlayback = false; nextSectionAt = nil
        recoveryAttempts += 1
        let attempt = recoveryAttempts, epoch = UUID(); connectionEpoch = epoch
        status = "连接中断，正在重连（\(attempt)/3）：" + reason
        addTurn(role: "system", text: status + "。待播音频已清空，未播放完的段落不会标为完成。", id: UUID().uuidString)
        recovery?.cancel()
        recovery = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(1 << (attempt - 1)) * 1_000_000_000)
            guard let self, !Task.isCancelled, self.active, self.allowAgent, self.connectionEpoch == epoch else { return }
            self.startConversation()
        }
    }
    func handlePresentationInput(_ text: String) {
        let lower = text.lowercased()
        let continuing = Self.isSimpleContinuation(text)
        let concluding = ["说个结尾", "讲个结尾", "做个结尾", "说下结尾", "收个尾", "收尾", "wrap up", "conclude the presentation"].contains(where: lower.contains)
        let explicitPause = ["先别讲", "先别说", "不用讲", "不要讲", "别讲了", "不要说", "别说了", "先停", "停一下", "停一停", "暂停", "等等", "等一下", "先到这", "先到这里", "说到这", "讲到这", "聊到这", "不要反复", "别反复", "不要重复", "别重复", "不要继续", "别继续", "不继续", "不用继续", "stop", "wait", "hold on", "that's enough", "don't continue", "do not continue", "don't go on", "do not go on", "discontinue"].contains(where: lower.contains)
        let holding = ["打断", "有个问题", "有一个问题", "我想问一下", "问个问题", "问一个问题", "let me ask", "i have a question", "can i interrupt", "can i ask", "may i ask"].contains(where: lower.contains)
        // A polite permission question is not the actual question the participant wants to ask.
        var subject = lower
        for phrase in ["可以吗", "好吗", "行吗", "问一个问题吗", "问个问题吗", "can i interrupt", "can i ask a question", "may i ask a question", "is that okay"] {
            subject = subject.replacingOccurrences(of: phrase, with: "")
        }
        let actualQuestion = ["什么", "为什么", "怎么", "哪个", "哪种", "多少", "谁", "能不能", "是不是", "是否", "有没有", "区别", "想法", "吗", "what", "why", "how", "which", "who"].contains(where: subject.contains)
        if explicitPause { _ = applyPresentationControl("pause") }
        else if concluding { _ = applyPresentationControl("conclude") }
        else if continuing {
            interruptPlayback(); realtime.suppressReplyForPresentationResume()
            _ = applyPresentationControl("resume")
        }
        else if holding && !actualQuestion { awaitingQuestion = true; presentationPaused = true }
        else if awaitingQuestion && actualQuestion { awaitingQuestion = false; presentationPaused = false }
        if !continuing && !explicitPause && !concluding && !holding && text.count > 3 { lastDiscussion = String(text.prefix(300)); transitionPending = true }
    }
    static func isSimpleContinuation(_ text: String) -> Bool {
        var normalized = text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        guard ["继续", "接着讲", "接着说", "continue", "goon"].contains(where: normalized.contains) else { return false }
        for phrase in ["继续介绍", "继续讲", "继续说", "接着讲", "接着说", "继续", "goon", "continue", "please", "okay", "好的", "可以", "ok", "好", "嗯", "呃", "那", "你", "先", "再", "就", "请", "吧", "啊", "呀", "了"] { normalized = normalized.replacingOccurrences(of: phrase, with: "") }
        return normalized.isEmpty
    }
    /// Changes the presentation agenda only. It never changes who owns the microphone or ends a meeting.
    func applyPresentationControl(_ action: String) -> String {
        guard ["pause", "resume", "conclude"].contains(action) else { return "{\"applied\":false,\"reason\":\"Unknown action.\"}" }
        awaitingQuestion = false
        if action == "resume" {
            if sectionRequested || sectionResponse != nil || completedSectionWaitingForPlayback { interruptPlayback() }
            presentationPaused = false; presentationConcluded = false
            transitionPending = true; nextSectionAt = Date().addingTimeInterval(1.5)
        } else {
            presentationPaused = true
            if action == "conclude" { presentationConcluded = true }
            // A tool call can replace an in-progress outline response. Do not count that outline as played.
            interruptPlayback()
        }
        trace("presentation_control action=" + action)
        return "{\"applied\":true,\"action\":\"\(action)\",\"automatic_outline_paused\":\(presentationPaused),\"concluded\":\(presentationConcluded)}"
    }
    func togglePresentationPause() {
        _ = applyPresentationControl(presentationPaused ? "resume" : "pause")
    }
    private func interruptPlayback() {
        if sectionRequested || sectionResponse != nil || completedSectionWaitingForPlayback { sectionWasInterrupted = true }
        var interrupted = queuedReplyIDs
        if let sectionResponse { interrupted.insert(sectionResponse) }
        for id in interrupted { interruptedReplyIDs.insert(id); setDelivery(id, interrupted: true) }
        queuedReplyIDs.removeAll()
        audio.gate.clearAgent()
        sectionRequested = false; sectionResponse = nil; completedSectionWaitingForPlayback = false
        nextSectionAt = nil
        if sectionIndex > 0 || !interrupted.isEmpty { transitionPending = true }
    }
    private func setDelivery(_ id: String, interrupted: Bool) {
        guard var record, let index = record.turns.firstIndex(where: { $0.id == id && ["pico", "pico_interrupted"].contains($0.role) }) else { return }
        record.turns[index].delivery = interrupted ? "interrupted" : "locally_rendered"
        if interrupted { record.turns[index].role = "pico_interrupted" }
        self.record = record; turns = record.turns; saveRecord()
    }
    private func rememberRenderedText(_ id: String) {
        guard !rememberedReplyIDs.contains(id), let text = turns.first(where: { $0.id == id && $0.role == "pico" })?.text, !text.isEmpty else { return }
        rememberedReplyIDs.insert(id); renderedReplyTexts.append(String(text.prefix(600)))
        if renderedReplyTexts.count > 8 { renderedReplyTexts.removeFirst(renderedReplyTexts.count - 8) }
    }
    private func advancePresentation() {
        guard active, agentSpeaking, allowAgent else { return }
        if audio.gate.bufferedSeconds > 0 { status = "Pico 正在讲话 · 可以随时打断"; return }
        let drained = queuedReplyIDs.intersection(finishedReplyIDs).subtracting(interruptedReplyIDs)
        for id in drained { renderedReplyIDs.insert(id); setDelivery(id, interrupted: false); rememberRenderedText(id) }
        queuedReplyIDs.subtract(drained)
        if !drained.isEmpty { nextSectionAt = Date().addingTimeInterval(1.5) }
        guard preparation.draft.present else { return }
        let sections = preparation.draft.sections
        if completedSectionWaitingForPlayback {
            guard let response = sectionResponse, renderedReplyIDs.contains(response) else { return }
            completedSectionWaitingForPlayback = false; sectionResponse = nil; sectionIndex += 1
            trace("presentation_section_played index=\(sectionIndex)")
            sectionWasInterrupted = false
            transitionPending = false; lastDiscussion = ""
            nextSectionAt = Date().addingTimeInterval(1.5)
        }
        presentationStatus = presentationConcluded ? "介绍已按请求收束 · 继续聆听和回答问题" : (sectionIndex >= sections.count ? "介绍已完成 · 继续聆听和回答问题" : "已播完 \(sectionIndex)/\(sections.count) 段" + (presentationPaused ? " · 介绍已暂停" : ""))
        guard !presentationPaused, !presentationConcluded, sectionIndex < sections.count, !sectionRequested, sectionResponse == nil,
              let deadline = nextSectionAt, Date() >= deadline, realtime.canRequestTurn else { return }
        let continuation = sectionWasInterrupted ? " This section was interrupted during playback or owner control. Its beginning may already have been heard. Reconnect in ONE short natural sentence and add only its remaining point. Do not repeat its example, opening or previous definition. If the question already covered the point, use a brief transition instead. Exact heard words are not verified." : ""
        let transition = transitionPending ? " Return naturally from the recent conversation (\(lastDiscussion.isEmpty ? "a pause in the conversation" : lastDiscussion)). Use one short, topic-specific transition, then the remaining point. Do not say '好的，那我继续' repeatedly, explain local takeover controls, or restart the introduction." : ""
        let covered = renderedReplyTexts.suffix(6).joined(separator: "\n")
        let instruction = "APP-SCHEDULED PRESENTATION TURN. Present only outline section \(sectionIndex + 1) of \(sections.count): \(sections[sectionIndex]). Use only supplied facts. Speak 2–4 short natural sentences, under 140 Chinese characters or 75 English words. Do not read the title, jump to other sections, or ask permission after every section. Facts already explained in a completed answer count as covered; do not repeat them. If this section is already covered, make one short transition without repeating its definition or example. The application schedules the next section after actual playback. Previously locally rendered replies (not proof of remote audibility):\n\(covered)" + continuation + transition
        if realtime.requestSpokenTurn(instruction) { sectionRequested = true; nextSectionAt = nil; status = "正在准备第 \(sectionIndex + 1) 段" }
    }
    private func trace(_ event: String) {
        guard !event.hasPrefix("response.audio.delta"), !event.hasPrefix("response.audio_transcript.delta"), !event.hasPrefix("conversation.item.input_audio_transcription.delta") else { return }
        traceEvents.append(ISO8601DateFormatter().string(from: Date()) + " " + event)
        if traceEvents.count > 1000 { traceEvents.removeFirst(traceEvents.count - 1000) }
        let folder = dataDir.appendingPathComponent("pico-meetings")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent("connection-events.log")
        try? traceEvents.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func finish() {
        guard active else {
            takeOver(); audio.stop(); routeConfirmed = false
            status = "Meeting ended. Microphone and audio bridge stopped."
            return
        }
        stopAgent("会议已结束，麦克风和音频桥已停止", handToHuman: false)
        addTurn(role: "system", text: "会议已结束。", id: UUID().uuidString)
        audio.stop(); routeConfirmed = false
        active = false; generation = UUID(); timer?.invalidate(); timer = nil; flowTimer?.invalidate(); flowTimer = nil
        let recorder = capture; capture = nil
        Task { await recorder?.stop() }
        if var record {
            record.ended = Date(); self.record = record; saveRecord(); handoff(record)
        }
        // Ending a meeting releases capture; only in-meeting takeover keeps the mic bridge alive.
    }
    func disconnect() { finish(); audio.stop(); status = "Audio bridge stopped. Select your physical microphone in Zoom."; routeConfirmed = false }
    private func addTurn(role: String, text: String, id: String) {
        guard active, var record else { return }
        let assistant = ["pico", "pico_interrupted"].contains(role)
        let interrupted = role == "pico_interrupted" || interruptedReplyIDs.contains(id)
        let resolvedRole = assistant && interrupted ? "pico_interrupted" : role
        record.turns.removeAll { $0.id == id && ($0.role == resolvedRole || (assistant && ["pico", "pico_interrupted"].contains($0.role))) }
        let delivery: String? = assistant ? (interrupted ? "interrupted" : renderedReplyIDs.contains(id) ? "locally_rendered" : "generated") : nil
        record.turns.append(.init(id: id, role: resolvedRole, text: String(text.prefix(24000)), time: Date().timeIntervalSince(record.started), delivery: delivery))
        self.record = record; turns = record.turns; saveRecord()
        if delivery == "locally_rendered" { rememberRenderedText(id) }
    }
    private func saveRecord() {
        guard let record, !savingRecord else { return }
        savingRecord = true; defer { savingRecord = false }
        do {
            let folder = dataDir.appendingPathComponent("pico-meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = folder.appendingPathComponent(record.id.uuidString + ".json")
            try JSONEncoder().encode(record).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { takeOverWithoutLogging("Could not save the conversation. You have control.") }
    }
    private func takeOverWithoutLogging(_ message: String) { stopAgent(message) }
    #if TELOS_TEST
    func activateForMeetingLifecycleTesting(meetingID: UUID, started: Date) {
        record = PicoMeetingRecord(started: started, title: "Controlled lifecycle test", meetingID: meetingID)
        active = true; allowAgent = true; agentSpeaking = true; humanHasControl = false
        audio.gate.switchTo(.agent)
    }
    static func verifyNaturalContinuation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pico-natural-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let flow = PicoMeetingController(dataDir: root) { _ in }
        flow.activateForMeetingLifecycleTesting(meetingID: UUID(), started: Date())
        flow.preparation.draft.present = true; flow.preparation.draft.outline = "First point\nSecond point"
        var sent: [[String: Any]] = []; flow.realtime.onSentEvent = { sent.append($0) }
        flow.realtime.injectDiagnosticEvent(["type": "session.updated"])
        flow.sectionIndex = 1; flow.nextSectionAt = .distantPast; flow.advancePresentation()
        let pcm = Data(repeating: 0, count: 200)
        flow.realtime.injectDiagnosticEvent(["type": "response.created", "response": ["id": "partial-intro"]])
        flow.realtime.onAudio?(pcm, "partial-intro")
        flow.realtime.onTranscript?("pico", "A partially played example must not be restarted.", "partial-intro")
        flow.realtime.injectDiagnosticEvent(["type": "response.done", "response": ["id": "partial-intro", "status": "completed"]])
        precondition(flow.nextSectionAt == nil && flow.sectionIndex == 1, "a generated reply must not start the next-section clock while audio is queued")
        flow.takeOver()
        precondition(flow.sectionWasInterrupted && flow.turns.last(where: { $0.id == "partial-intro" })?.delivery == "interrupted", "takeover after generation still interrupts local playback")
        flow.allowAgent = true; flow.agentSpeaking = true; flow.realtime.injectDiagnosticEvent(["type": "session.updated"])
        flow.lastDiscussion = "Where did the idea come from?"; flow.transitionPending = true
        flow.nextSectionAt = .distantPast; flow.advancePresentation()
        let messages = sent.compactMap { ($0["item"] as? [String: Any])?["content"] as? [[String: Any]] }.flatMap { $0 }.compactMap { $0["text"] as? String }
        precondition(messages.last?.contains("ONE short natural sentence") == true && messages.last?.contains("Where did the idea come from?") == true, "resumption must include the interrupted point and the actual discussion for a natural transition")
        flow.finish(); flow.shutdown()
        let answer = PicoMeetingController(dataDir: root.appendingPathComponent("answer")) { _ in }
        answer.activateForMeetingLifecycleTesting(meetingID: UUID(), started: Date())
        answer.realtime.injectDiagnosticEvent(["type": "session.updated"])
        answer.realtime.injectDiagnosticEvent(["type": "response.created", "response": ["id": "answer"]])
        answer.realtime.onAudio?(pcm, "answer"); answer.realtime.onTranscript?("pico", "The answer has already explained this fact.", "answer")
        answer.realtime.injectDiagnosticEvent(["type": "response.done", "response": ["id": "answer", "status": "completed"]])
        answer.advancePresentation(); precondition(answer.nextSectionAt == nil)
        let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!, frameCapacity: 100)!
        buffer.frameLength = 100; answer.audio.gate.render(100, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        answer.advancePresentation()
        precondition((answer.nextSectionAt?.timeIntervalSinceNow ?? 0) > 1 && answer.renderedReplyTexts.count == 1, "pacing and covered facts are committed only after actual local render drain")
        precondition(answer.turns.first(where: { $0.id == "answer" })?.delivery == "locally_rendered")
        answer.pauseForMeetingUncertainty(); answer.audio.gate.append([0.5], from: .human)
        answer.audio.gate.render(100, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        precondition(buffer.floatChannelData![0][0] == 0, "uncertain meeting state must not silently activate the owner's live microphone")
        answer.finish(); answer.shutdown()
        precondition(isSimpleContinuation("嗯，先继续吧") && isSimpleContinuation("继续吧，继续讲吧") && !isSimpleContinuation("你为什么继续讲这个问题？"))
        print("PASS: one agenda writer, partial-playback preservation, grounded transition context, render-drain pacing, and uncertain-state silence")
    }
    /// Drives the real callbacks, gate, failure path, persistence and handoff without a meeting or network.
    static func verifyControlledLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-lifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var handedOff: [PicoMeetingRecord] = []
        let controller = PicoMeetingController(dataDir: directory) { handedOff.append($0) }
        controller.active = true; controller.allowAgent = true
        controller.record = PicoMeetingRecord(title: "Controlled local test")
        let samples = [Int16](repeating: 8000, count: 100)
        let pcm = samples.withUnsafeBytes { Data($0) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100)!
        buffer.frameLength = 100
        func rendered() -> [Float] {
            controller.audio.gate.render(100, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
            return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 100))
        }
        controller.realtime.onReady?()
        controller.realtime.injectDiagnosticEvent(["type": "response.created", "response": ["id": "test-response"]])
        controller.realtime.injectDiagnosticEvent(["type": "response.audio.delta", "response_id": "test-response", "delta": pcm.base64EncodedString()])
        precondition(rendered().contains { $0 > 0.2 })
        controller.realtime.onAudio?(pcm, "test-response")
        controller.realtime.injectDiagnosticEvent(["type": "input_audio_buffer.speech_started"])
        controller.realtime.injectDiagnosticEvent(["type": "response.audio.delta", "response_id": "test-response", "delta": pcm.base64EncodedString()])
        precondition(rendered().allSatisfy { $0 == 0 }, "barge-in must flush and block late response audio")
        controller.realtime.onTranscript?("other", "I enjoy hiking. Could the owner suggest a route?", "other-1")
        controller.realtime.onTranscript?("pico", "I will pass that question to the owner.", "pico-1")
        controller.realtime.onAudio?(pcm, "test-response-2")
        controller.realtime.injectDiagnosticEvent(["type": "error", "error": ["code": "controlled_disconnect"]])
        precondition(!controller.agentSpeaking && !controller.connecting && controller.status.contains("controlled_disconnect"))
        precondition(rendered().allSatisfy { $0 == 0 }, "provider failure must synchronously flush playback")
        controller.realtime.onAudio?(pcm, "late-after-failure")
        precondition(rendered().allSatisfy { $0 == 0 })
        precondition(controller.turns.last?.text.contains("controlled_disconnect") == true)
        precondition(controller.turns.last?.text.contains("不是用户接管") == true)
        let pausedCount = controller.turns.count
        controller.pauseForFailure("duplicate callback")
        precondition(controller.turns.count == pausedCount, "late failure must not duplicate stop events")
        controller.allowAgent = true; controller.agentSpeaking = true
        controller.recoverConnection("controlled reconnect")
        precondition(controller.connecting && !controller.agentSpeaking)
        controller.takeOver()
        precondition(!controller.allowAgent && controller.recovery == nil, "human takeover must cancel scheduled reconnect")
        let takeoverCount = controller.turns.count
        controller.takeOver()
        precondition(controller.turns.count == takeoverCount)
        controller.finish(); controller.finish()
        precondition(handedOff.count == 1 && handedOff[0].ended != nil)
        precondition(!controller.audio.running && !controller.routeConfirmed)
        controller.audio.gate.append([0.5], from: .human)
        precondition(rendered().allSatisfy { $0 == 0 }, "Finished meetings must not pass microphone audio")
        precondition(handedOff[0].turns.contains { $0.role == "other" && $0.id == "other-1" })
        let saved = directory.appendingPathComponent("pico-meetings/" + handedOff[0].id.uuidString + ".json")
        let restored = try JSONDecoder().decode(PicoMeetingRecord.self, from: Data(contentsOf: saved))
        precondition(restored.ended != nil && restored.turns.count == handedOff[0].turns.count)
        controller.shutdown()
        let flow = PicoMeetingController(dataDir: directory) { _ in }
        flow.active = true; flow.allowAgent = true
        flow.record = PicoMeetingRecord(title: "Presentation playback test")
        flow.preparation.draft.present = true; flow.preparation.draft.outline = "第一段\n第二段"
        var sent: [[String: Any]] = []
        flow.realtime.onSentEvent = { sent.append($0) }
        flow.realtime.injectDiagnosticEvent(["type": "session.updated"])
        flow.nextSectionAt = Date.distantPast; flow.advancePresentation()
        precondition(flow.sectionRequested && sent.filter { $0["type"] as? String == "response.create" }.count == 1)
        flow.realtime.injectDiagnosticEvent(["type": "response.created", "response": ["id": "section-1"]])
        flow.realtime.onAudio?(pcm, "section-1")
        flow.realtime.injectDiagnosticEvent(["type": "response.done", "response": ["id": "section-1", "status": "completed"]])
        flow.advancePresentation(); precondition(flow.sectionIndex == 0, "generated does not mean played")
        flow.audio.gate.render(100, into: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList))
        flow.advancePresentation(); precondition(flow.sectionIndex == 1)
        flow.nextSectionAt = Date.distantPast; flow.advancePresentation()
        flow.realtime.injectDiagnosticEvent(["type": "response.created", "response": ["id": "section-2"]])
        flow.realtime.injectDiagnosticEvent(["type": "input_audio_buffer.speech_started"])
        flow.realtime.injectDiagnosticEvent(["type": "response.done", "response": ["id": "section-2", "status": "cancelled"]])
        flow.advancePresentation(); precondition(flow.sectionIndex == 1, "interrupted section must remain pending")
        flow.handlePresentationInput("我打断你一下。")
        precondition(flow.presentationPaused && flow.awaitingQuestion, "do not restart presentation while waiting for a question")
        flow.handlePresentationInput("嗯，可以啊。")
        precondition(flow.presentationPaused)
        flow.handlePresentationInput("你叫什么名字？")
        precondition(!flow.presentationPaused && !flow.awaitingQuestion)
        flow.handlePresentationInput("先别讲")
        flow.handlePresentationInput("你是什么？")
        precondition(flow.presentationPaused, "explicit pause must persist")
        flow.handlePresentationInput("继续")
        precondition(!flow.presentationPaused)
        let playedSections = flow.sectionIndex
        flow.sectionResponse = "interrupted-outline"; flow.completedSectionWaitingForPlayback = true
        _ = flow.applyPresentationControl("conclude")
        flow.nextSectionAt = Date.distantPast; flow.advancePresentation()
        precondition(flow.sectionIndex == playedSections && !flow.sectionRequested, "conclusion must stop the agenda without falsely completing an interrupted section")
        precondition(flow.allowAgent && flow.agentSpeaking, "presentation control must keep conversation and audio ownership unchanged")
        flow.finish(); flow.shutdown()
    }
    #endif
    func shutdown() { finish(); audio.stop(); startup?.cancel(); realtime.stop(); if let monitor { NSEvent.removeMonitor(monitor) }; if let localMonitor { NSEvent.removeMonitor(localMonitor) } }
}

struct PicoMeetingView: View {
    @ObservedObject var controller: PicoMeetingController
    @State private var showMemory = false
    @StateObject private var connectionCheck = PicoConnectionCheck()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Pico, join the conversation").font(.title2)
                Text("A relaxed 1-on-1 · Pico identifies itself as your AI representative. Audio and background go to Bailian. Handoff summaries use your configured text model. Records are saved in Telos.").font(.callout).foregroundStyle(.secondary)
                Button("Bailian API key…") { BailianCredentialWindow.shared.show() }.disabled(controller.active || controller.connecting)
                HStack {
                    Button(connectionCheck.running ? "停止检查" : "检查模型、知识和 10 分钟稳定性（不向会议播放）") {
                        if connectionCheck.running { connectionCheck.cancel() } else { connectionCheck.run(directory: controller.dataDir) }
                    }.disabled(controller.active || controller.connecting)
                }
                Text(connectionCheck.status.isEmpty ? "约 10 分钟，仅向百炼发送虚构测试资料；检查回复、记忆调用和空闲恢复，不开麦、不向会议发声。" : connectionCheck.status).font(.caption).foregroundStyle(.secondary)
                Toggle("使用 Telos 记忆回答问题", isOn: $controller.memoryEnabled).disabled(controller.active || controller.connecting)
                Text("相关记忆会发送给百炼，并可能用于回答参会者。可在会前查看或排除不想分享的条目。").font(.caption).foregroundStyle(.secondary)
                Button("查看用于会议的记忆…") { showMemory = true }.disabled(controller.active || controller.connecting)
                if !controller.memoryStatus.isEmpty { Text(controller.memoryStatus).font(.caption).foregroundStyle(.secondary) }
                PicoPreparationView(store: controller.preparation, disabled: controller.active || controller.connecting)
                Picker("Your microphone", selection: $controller.microphoneID) {
                    Text("Choose microphone").tag(AudioDeviceID(0))
                    ForEach(controller.devices.filter { $0.physical }) { Text($0.name).tag($0.id) }
                }.disabled(controller.active)
                Picker("Zoom microphone bridge", selection: $controller.virtualID) {
                    Text("BlackHole 2ch required").tag(AudioDeviceID(0))
                    ForEach(controller.devices.filter { $0.virtual && $0.input && $0.output }) { Text($0.name).tag($0.id) }
                }.disabled(controller.active)
                HStack {
                    Button("Refresh audio devices") { controller.refreshDevices() }
                    if controller.virtualID == 0 { Link("Get BlackHole", destination: URL(string: "https://existential.audio/blackhole/")!) }
                }
                Toggle("Zoom 麦克风已选 BlackHole 并取消静音；扬声器已避免回声；对方知道 Pico 是 AI 助手", isOn: $controller.routeConfirmed).disabled(controller.active)
                Text(controller.status).font(.callout).textSelection(.enabled)
                if controller.active && controller.preparation.draft.present {
                    HStack {
                        Text(controller.presentationStatus).font(.caption)
                        Button(controller.presentationPaused ? "继续介绍" : "暂停介绍") { controller.togglePresentationPause() }
                    }
                }
                HStack {
                    if controller.active {
                        Button("Take over now  ⌃⌥Space") { controller.takeOver() }.buttonStyle(.borderedProminent)
                        Button("Let Pico continue") { controller.resume() }.disabled(controller.agentSpeaking || controller.connecting)
                        Button("Finish & hand off") { controller.finish() }
                    } else {
                        Button(controller.connecting ? "Connecting…" : "Start Pico in this meeting") { controller.start() }
                            .disabled(!controller.routeConfirmed || controller.virtualID == 0 || controller.connecting || connectionCheck.running)
                    }
                }
                Button("Disconnect audio bridge") { controller.disconnect() }
                Text("Take over switches to your real microphone immediately, even offline. Keep this app open while Zoom uses BlackHole. Finishing stops the microphone and bridge. Select your physical microphone in Zoom for your next meeting.").font(.caption).foregroundStyle(.secondary)
                if !controller.turns.isEmpty {
                    Divider()
                    ForEach(controller.turns.suffix(30)) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(turn.role == "other" ? "Other person" : turn.role == "pico" ? (turn.delivery == "locally_rendered" ? "Pico · 本机已播放" : "Pico · generated response") : turn.role == "pico_interrupted" ? "Pico · 播放被打断" : "Session").font(.caption).foregroundStyle(.secondary)
                            Text(turn.text).textSelection(.enabled)
                        }
                    }
                }
            }.padding(22)
        }.frame(minWidth: 490, minHeight: 520)
            .sheet(isPresented: $showMemory) { PicoMemoryReview(directory: controller.dataDir) }
    }
}
