import AppKit
import AVFoundation
import Speech
import Combine

@MainActor final class MeetingSessionManager: ObservableObject {
    @Published var enabled = MeetingMonitoringPreference.enabled(in: .standard)
    @Published var setupMessage = ""
    @Published var preparing = false
    @Published var accessReady = false
    @Published private(set) var accessibilityReady = false
    @Published private(set) var screenAudioReady = false
    @Published private(set) var microphoneReady = false
    @Published private(set) var repairMessage = ""
    @Published private(set) var repairingAccess = false
    var capturing: Bool { activeID != nil }
    private var lastDiagnostic = ""
    private weak var store: TaskStore?
    private var timer: Timer?
    private var polling = false
    private var shuttingDown = false
    private var analysisTasks: [UUID: Task<Void, Never>] = [:]
    private var debouncer = MeetingDebouncer()
    private var activeID: UUID?
    private var suppressedPID: pid_t?
    private var captureFailure: String?
    private var lastAudio = Date.distantPast
    private var capture: (any MeetingAudioCapturing)?
    private let detector: any MeetingDetecting
    private let makeSpeech: (() -> any MeetingTranscribing)?
    private let makeCapture: (() -> any MeetingAudioCapturing)?
    private var transcriber: (any MeetingTranscribing)?
    private var starting: Task<Void, Never>?
    private var finishing = false
    private var persistTimer: Timer?
    private var dirty = false
    private var analysisIDs = Set<UUID>()
    var repository: MeetingRepository { MeetingRepository(directory: store!.dataDir.appendingPathComponent("meetings")) }
    init(store: TaskStore, detector: any MeetingDetecting = ZoomMeetingAdapter(), makeSpeech: (() -> any MeetingTranscribing)? = nil, makeCapture: (() -> any MeetingAudioCapturing)? = nil) {
        self.store = store; self.detector = detector; self.makeSpeech = makeSpeech; self.makeCapture = makeCapture
    }
    func start() {
        guard timer == nil else { return }
        refreshAccessState()
        do {
            for var session in try repository.load(onError: { self.setupMessage = $0 }) {
                if [.preparing, .recording, .finishing].contains(session.status) {
                    session.status = .interrupted; session.endTime = Date()
                    session.notice = "Telos stopped during this meeting. Saved transcript is preserved; the missing interval was not recorded."
                    try repository.save(session)
                }
                for i in session.suggestions.indices {
                    session.suggestions[i].createdTaskID = store?.tasks.first(where: { $0.sourceMeetingID == session.id && $0.sourceSuggestionID == session.suggestions[i].id })?.id
                }
                if session.analysisStatus == "analyzing" { session.analysisStatus = "failed" }
                store?.meetings[session.id] = session
                if store?.tasks.contains(where: { $0.meetingID == session.id }) != true { addTask(session) }
                updateTask(session)
            }
        } catch { setupMessage = "Could not read saved meetings: \(error.localizedDescription)" }
        timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        RunLoop.main.add(timer!, forMode: .common)
        persistTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flush() }
        }
        RunLoop.main.add(persistTimer!, forMode: .common)
    }
    func enable() {
        guard !preparing, !repairingAccess, activeID == nil else { return }
        guard #available(macOS 26, *) else { setupMessage = "Meeting transcription requires macOS 26 or later."; return }
        enabled = true; UserDefaults.standard.set(true, forKey: "TelosMeetingsEnabled")
        preparing = true; setupMessage = "Preparing on-device speech…"
        Task {
            defer { preparing = false; refreshAccessState() }
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard mic else { openPermissionSettings("Privacy_Microphone"); return }
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { openPermissionSettings("Privacy_ScreenCapture"); return }
            guard AXIsProcessTrusted() else {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                openPermissionSettings("Privacy_Accessibility"); return
            }
            do {
                if locale == "mixed" {
                    let engine = LocalMeetingTranscription()
                    try await engine.start(localeID: locale); await engine.finish()
                } else { try await MeetingTranscription.prepareAssets(localeID: locale) }
                enabled = true; UserDefaults.standard.set(true, forKey: "TelosMeetingsEnabled")
                accessReady = true
                suppressedPID = nil; captureFailure = nil; debouncer.reset()
                setupMessage = "Waiting for a Zoom meeting…"
            } catch { captureFailure = error.localizedDescription; setupMessage = error.localizedDescription }
        }
    }
    func openPermissionSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
        NSWorkspace.shared.open(url)
    }
    func repairAccessibility() {
        guard !repairingAccess, !preparing, activeID == nil else { return }
        repairingAccess = true
        Task {
            let result = await Task.detached(priority: .utility) { UpdatePermissionReset.resetAccessibility() }.value
            repairingAccess = false
            refreshAccessState()
            if result {
                repairMessage = "Old Accessibility permission cleared. Add this Telos app and turn it on in System Settings. If macOS asks, quit and reopen Telos."
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            } else {
                repairMessage = "macOS could not clear Accessibility. Remove Telos from the list, then add this app again and turn it on."
            }
            openPermissionSettings("Privacy_Accessibility")
        }
    }
    func revealInstalledApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
    var locale: String { UserDefaults.standard.string(forKey: "TelosMeetingLanguage") ?? "mixed" }
    func disable() {
        enabled = false; UserDefaults.standard.set(false, forKey: "TelosMeetingsEnabled")
        setupMessage = "Automatic meeting capture is off."
        writeDiagnostic(signal: "disabled")
        Task { await finish(interrupted: true, notice: "Meeting capture was turned off.") }
    }
    private func refreshAccessState() {
        let accessibility = AXIsProcessTrusted()
        let screen = CGPreflightScreenCaptureAccess()
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityReady = accessibility; screenAudioReady = screen; microphoneReady = mic
        accessReady = accessibility && screen && mic
        if !enabled { setupMessage = "Automatic meeting capture is off." }
        else if !preparing && activeID == nil {
            var missing: [String] = []
            if !accessibility { missing.append("Accessibility (meeting detection)") }
            if !screen { missing.append("Screen & System Audio Recording") }
            if !mic { missing.append("Microphone") }
            setupMessage = missing.isEmpty ? (captureFailure.map { "Capture stopped: " + $0 + ". Click Set up meeting access to retry this meeting." } ?? "Waiting for a Zoom meeting…") : "Permission needed: " + missing.joined(separator: ", ") + ". Click Set up meeting access."
        }
    }
    private func writeDiagnostic(signal: String) {
        guard let store else { return }
        let value: [String: Any] = ["enabled": enabled, "accessibility": AXIsProcessTrusted(), "screen_audio": CGPreflightScreenCaptureAccess(), "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "signal": signal, "status": setupMessage, "active": activeID != nil]
        guard let state = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let key = String(data: state, encoding: .utf8), key != lastDiagnostic else { return }
        lastDiagnostic = key
        var entry = value; entry["updated"] = ISO8601DateFormatter().string(from: Date())
        if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys]) {
            let file = store.dataDir.appendingPathComponent("meeting-status.json")
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    private func poll() {
        refreshAccessState()
        if !enabled { writeDiagnostic(signal: "disabled") }
        guard enabled, !preparing, !repairingAccess, !shuttingDown, !polling, !finishing, starting == nil else { return }
        polling = true
        Task {
            let detector = self.detector
            let observation = await Task.detached(priority: .utility) { detector.observe() }.value
            polling = false
            guard enabled, !shuttingDown else { return }
            if activeID == nil && accessReady && !preparing && suppressedPID == nil && captureFailure == nil {
                switch observation.signal {
                case .joined: setupMessage = "Zoom meeting detected. Starting transcription…"
                case .absent, .ended: setupMessage = "Waiting for a Zoom meeting…"
                case .unknown: setupMessage = "Zoom is open, but its meeting controls could not be confirmed yet."
                }
            }
            writeDiagnostic(signal: String(describing: observation.signal))
            if observation.signal == .joined && !accessReady { debouncer.reset(); return }
            await receive(observation, at: Date())
        }
    }
    func receive(_ observation: MeetingObservation, at now: Date) async {
        guard enabled, !preparing, !repairingAccess, !shuttingDown, !finishing, starting == nil else { return }
        if suppressedPID != nil {
            if (observation.signal == .absent || observation.signal == .ended) { suppressedPID = nil; debouncer.reset() }
            else { return }
        }
        if let changed = debouncer.update(observation.signal, at: now, remoteAudioRecently: now.timeIntervalSince(lastAudio) < 10) {
            if changed { begin(observation) }
            else { await finish(endedAt: debouncer.transitionTime) }
        }
    }
    private func addTask(_ session: MeetingSession) {
        guard let store else { return }
        var todo = Todo(title: session.title, summary: "Meeting in progress", status: "running")
        todo.meetingID = session.id
        store.tasks.insert(todo, at: 0); store.save()
    }
    private func updateTask(_ session: MeetingSession) {
        guard let store, let id = store.tasks.first(where: { $0.meetingID == session.id })?.id else { return }
        store.mutate(id) {
            $0.title = session.title
            if session.status == .completed || session.status == .interrupted {
                // Ending capture does not archive the user's task. Preserve manual completion.
                if $0.status != "completed" { $0.status = "ready"; $0.completedAt = nil }
                $0.summary = session.summary?.first?.text ?? (session.status == .completed ? "Meeting ended · Ready for review" : "Meeting interrupted · Transcript saved")
            } else { $0.status = "running"; $0.summary = session.status == .preparing ? "Preparing meeting transcription…" : "Recording & transcribing…" }
        }
        store.save()
    }
    private func begin(_ observation: MeetingObservation) {
        guard activeID == nil, let store, #available(macOS 26, *) else { return }
        let rawTitle = observation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = ["zoom", "zoom meeting", "zoom workplace", "会议", "zoom 会议", ""].contains(rawTitle.lowercased())
            ? "Zoom Meeting · " + Date().formatted(date: .abbreviated, time: .shortened) : rawTitle
        let session = MeetingSession(title: title, locale: locale, processID: observation.pid)
        do { try repository.save(session) } catch { setupMessage = "Could not save meeting: \(error.localizedDescription)"; debouncer.reset(); return }
        store.meetings[session.id] = session; activeID = session.id; lastAudio = .distantPast; captureFailure = nil
        addTask(session)
        starting = Task { [weak self] in
            guard let self else { return }
            do {
                let speech: any MeetingTranscribing
                if let makeSpeech { speech = makeSpeech() }
                else if session.locale == "mixed" { speech = LocalMeetingTranscription() }
                else { speech = MeetingTranscription() }
                let audio: any MeetingAudioCapturing = makeCapture?() ?? MeetingAudioCapture()
                transcriber = speech; capture = audio
                speech.onSegment = { [weak self] segment in await MainActor.run {
                    guard let self, self.activeID == session.id else { return }
                    self.store?.meetings[session.id]?.update(segment); self.dirty = true
                } }
                let reportError: (String) -> Void = { [weak self] text in Task { @MainActor in
                    guard let self, self.activeID == session.id else { return }
                    self.captureFailure = text
                    self.store?.meetings[session.id]?.notice = text
                    self.dirty = true
                    if self.starting == nil && !self.finishing { await self.finish(interrupted: true, notice: text) }
                } }
                speech.onError = reportError; audio.onError = reportError
                audio.onBuffer = { [weak speech] buffer, source, time in speech?.append(buffer, source: source, time: time) }
                audio.onActivity = { [weak self] in Task { @MainActor in self?.lastAudio = Date() } }
                try await speech.start(localeID: session.locale)
                try Task.checkCancellation()
                try await audio.start(pid: observation.pid, elapsed: Date().timeIntervalSince(session.startTime))
                try Task.checkCancellation()
                store.meetings[session.id]?.status = .recording
                dirty = true; flush()
                if let updated = store.meetings[session.id] { updateTask(updated) }
                starting = nil
            } catch {
                starting = nil
                await finish(interrupted: true, notice: error.localizedDescription)
            }
        }
    }
    func endByUser() {
        if let id = activeID { suppressedPID = store?.meetings[id]?.processID }
        Task { await finish() }
    }
    func finish(interrupted: Bool = false, notice: String? = nil, endedAt: Date? = nil) async {
        guard let id = activeID, !finishing, let store else { return }
        finishing = true
        let captureEndedAt = endedAt ?? Date()
        if let starting { starting.cancel(); await starting.value; self.starting = nil }
        store.meetings[id]?.status = .finishing
        await capture?.stop()
        await transcriber?.finish()
        // Result callbacks are delivered on the main actor before the final persistence.
        await Task.yield()
        let interrupted = interrupted || captureFailure != nil
        store.meetings[id]?.status = interrupted ? .interrupted : .completed
        store.meetings[id]?.endTime = max(store.meetings[id]?.startTime ?? captureEndedAt, captureEndedAt)
        if let notice = notice ?? captureFailure { store.meetings[id]?.notice = notice }
        if interrupted { suppressedPID = store.meetings[id]?.processID }
        dirty = true; flush()
        if let session = store.meetings[id] { updateTask(session) }
        activeID = nil; capture = nil; transcriber = nil; finishing = false
        refreshAccessState()
        writeDiagnostic(signal: interrupted ? "capture_failed" : "finished")
        if !interrupted && ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil { analyze(id) }
    }
    private func flush() {
        guard dirty, let id = activeID, let session = store?.meetings[id] else { return }
        do { try repository.save(session); dirty = false }
        catch { setupMessage = "Transcript could not be saved: \(error.localizedDescription)"; store?.meetings[id]?.notice = setupMessage }
    }
    func analyze(_ id: UUID) {
        guard !analysisIDs.contains(id), let store, let session = store.meetings[id], [.completed, .interrupted].contains(session.status) else { return }
        analysisIDs.insert(id); store.meetings[id]?.analysisStatus = "analyzing"
        analysisTasks[id] = Task {
            defer { analysisIDs.remove(id); analysisTasks[id] = nil }
            do {
                let result = try await MeetingUnderstanding.analyze(session, dataDir: store.dataDir)
                if let error = result.error { throw NSError(domain: "Meeting", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                var updated = store.meetings[id] ?? session
                let created = updated.suggestions.filter { $0.createdTaskID != nil }
                updated.suggestions = created + (result.suggestions ?? []).filter { candidate in
                    MeetingUnderstanding.verified(candidate.evidence, in: session) && candidate.confidence >= 0.85 && !created.contains { $0.evidence.segmentID == candidate.evidence.segmentID && $0.evidence.text == candidate.evidence.text }
                }
                updated.decisions = (result.decisions ?? []).filter { MeetingUnderstanding.verified($0.evidence, in: session) }
                updated.summary = (result.summary ?? []).filter { MeetingUnderstanding.verified($0.evidence, in: session) }
                if let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, !(updated.summary ?? []).isEmpty {
                    updated.title = String(title.prefix(160))
                }
                updated.analysisStatus = "ready"
                try repository.save(updated); store.meetings[id] = updated; updateTask(updated)
            } catch {
                store.meetings[id]?.analysisStatus = "failed"
                store.meetings[id]?.notice = "Analysis did not finish. Transcript is saved; you can retry."
                if let updated = store.meetings[id] { try? repository.save(updated) }
            }
        }
    }
    func shutdown() async {
        shuttingDown = true
        timer?.invalidate(); persistTimer?.invalidate()
        let pendingAnalysis = Array(analysisTasks.values)
        for task in pendingAnalysis { task.cancel() }
        for task in pendingAnalysis { await task.value }
        await finish(interrupted: true, notice: "Telos closed during this meeting. Saved transcript is retained.")
    }
}
