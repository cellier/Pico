import AppKit
import AVFoundation
import ApplicationServices

@MainActor protocol DictationInputSurfaceProviding { var dictationInputSurface: NSView? { get } }

/// Pure hold policy: a stationary left press, never a drag, arms dictation.
struct DictationHold {
    private(set) var origin: CGPoint?
    mutating func begin(_ point: CGPoint) { origin = point }
    mutating func move(_ point: CGPoint) { if let origin, hypot(point.x-origin.x, point.y-origin.y) > 6 { self.origin = nil } }
    mutating func cancel() { origin = nil }
}

/// Selection alone is not editing: labels and read-only text can expose ranges.
struct DictationEditability {
    static func allows(role: String, enabled: Bool?, editable: Bool?, secure: Bool,
                       hasInsertionRange: Bool, writableText: Bool, writableValue: Bool) -> Bool {
        let textRole = [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
        let richEditor = role == kAXGroupRole && editable == true
        guard textRole || richEditor,
              !secure, enabled != false, editable != false, (hasInsertionRange || editable == true) else { return false }
        return writableText || writableValue || editable == true
    }
}

/// Some web editors expose their focused AX node after the mouse-down callback.
struct DictationActivation {
    private var lastAttempt = -Double.infinity
    mutating func shouldAttempt(elapsed: TimeInterval) -> Bool {
        guard elapsed >= 0.55, elapsed - lastAttempt >= 0.15 else { return false }
        lastAttempt = elapsed
        return true
    }
    static func expired(elapsed: TimeInterval) -> Bool { elapsed >= 1.4 }
}

@MainActor final class DictationController {
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var permissionTimer: Timer?
    private var lastTrusted: Bool?
    private weak var pressWindow: NSWindow?
    private var hold = DictationHold()
    private var arm: Timer?
    private var deadline: Task<Void, Never>?
    private var recorder: AVAudioRecorder?
    private let engine = DictationEngine()
    private let cloudDictation = BailianDictation()
    private lazy var recognition = DictationRecognition(cloud: cloudDictation, local: engine)
    private var companionGestureUntil = Date.distantPast
    @objc private func companionGesture(_ note: Notification) {
        let down=note.userInfo?["down"] as? Bool ?? false
        companionGestureUntil=Date().addingTimeInterval(down ? 1.5:0.2)
        // Pet owns this pointer gesture. Do not arm global text-field dictation.
        arm?.invalidate();hold.cancel();attemptedTarget=false
        if recorder == nil {hud?.orderOut(nil)}
    }
    private var companionBusy = false
    func transcribeCompanion(_ url: URL, reply: @escaping ([String:Any])->Void) {
        guard recorder == nil, !busy, !companionBusy else {reply(["error":"Dictation is active"]);return}
        companionBusy = true
        engine.transcribe(url,polish:false) { [weak self] value in
            if value["stage"] == nil {self?.companionBusy=false}
            reply(value)
        }
    }
    func cancelCompanion() { if companionBusy {engine.cancel();companionBusy=false} }
    private var audioURL: URL?
    private var target: Target?
    private var hud: NSPanel?
    private var hudGeneration = UUID()
    private var busy = false
    private var insertionPending = false
    private var insertionID = UUID()
    private var preparedApps = Set<pid_t>()
    private var targetMessage = "Click inside an editable text field, then hold again"
    private var diagnostic: [String: Any] = [:]
    private var attemptedTarget = false
    private var diagnosticClickID = UUID()
    private var accessibilityRequests: [pid_t: [String: Int32]] = [:]
    var enabled = true
    private struct Target {
        weak var editor: NSTextView?
        let element: AXUIElement?
        let pid: pid_t
        let range: NSRange?
        let axRange: CFTypeRef?
    }
    func start() {
        guard localMonitor == nil else { return }
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(companionGesture(_:)),name:Notification.Name("local.original.sprout.gesture"),object:"local.original.sprout")
        engine.warm()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event, local: true); return event
        }
        refreshGlobalMonitor()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshGlobalMonitor() }
        }
        permissionTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func refreshGlobalMonitor() {
        let trusted = AXIsProcessTrusted()
        guard trusted != lastTrusted || globalMonitor == nil else { return }
        lastTrusted = trusted
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        // Mouse monitoring itself does not need Accessibility. Keep it alive so a
        // denied permission produces an actionable HUD instead of a silent hold.
        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .leftMouseDragged]
        if trusted { mask.insert(.keyDown) }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event, local: false)
        }
        diagnostic["global_monitor"] = globalMonitor != nil
        diagnostic["accessibility"] = trusted
        trace("monitor_ready")
    }
    static func localEditor(in window: NSWindow, at point: NSPoint) -> NSTextView? {
        guard let editor = window.firstResponder as? NSTextView, editor.isEditable,
              !(editor.delegate is NSSecureTextField), !editor.isHiddenOrHasHiddenAncestor else { return nil }
        let surface = (editor as? DictationInputSurfaceProviding)?.dictationInputSurface
            ?? (editor.isFieldEditor ? editor.delegate as? NSView : nil) ?? editor
        guard surface.window === window, !surface.isHiddenOrHasHiddenAncestor else { return nil }
        // Glass/SwiftUI hosting overlays may win hitTest even over the native editor.
        // The focused editable control and its own padded bounds are authoritative.
        guard surface.bounds.contains(surface.convert(point, from: nil))
            || editor.bounds.contains(editor.convert(point, from: nil)) else { return nil }
        return editor
    }
    func requestPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
    private func handle(_ event: NSEvent, local: Bool) {
        guard !companionBusy, Date() >= companionGestureUntil else {return}
        guard enabled, UserDefaults.standard.object(forKey: "TelosVoiceTypingEnabled") == nil || UserDefaults.standard.bool(forKey: "TelosVoiceTypingEnabled") else { cancel(); return }
        switch event.type {
        case .leftMouseDown:
            guard !busy, !insertionPending else {
                if recorder == nil { show(insertionPending ? "Inserting previous text…" : "Still transcribing your previous recording…") }
                return
            }
            pressWindow = local ? event.window : nil
            attemptedTarget = false
            diagnostic = ["local": local, "accessibility": AXIsProcessTrusted()]
            diagnostic["button_down"] = NSEvent.pressedMouseButtons & 1 != 0
            trace("pressed")
            if !local { prepareAccessibility() }
            diagnosticClickID = UUID()
            if UserDefaults.standard.bool(forKey: "TelosDictationDiagnostics") {
                let clickID = diagnosticClickID
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    guard let self, self.diagnosticClickID == clickID, !self.busy else { return }
                    let recognized = self.inputTarget() != nil
                    self.recordDiagnostic(recognized ? "editor_found" : "editor_unavailable", fileName: "dictation-target.json")
                }
            }
            arm?.invalidate(); hold.begin(NSEvent.mouseLocation)
            let started = Date(); var activated = false; var activation = DictationActivation()
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return };guard Date() >= self.companionGestureUntil else {timer.invalidate();return}
                    guard NSEvent.pressedMouseButtons & 1 != 0 else { self.localMouseReleased(); return }
                    self.hold.move(NSEvent.mouseLocation)
                    guard self.hold.origin != nil else { self.cancel(); return }
                    let elapsed = Date().timeIntervalSince(started)
                    if !activated && activation.shouldAttempt(elapsed: elapsed) {
                        activated = self.beginRecording()
                        if !activated && DictationActivation.expired(elapsed: elapsed) {
                            self.recordDiagnostic("target_unavailable")
                            self.show(self.targetMessage, dismiss: true)
                            self.attemptedTarget = false
                            timer.invalidate()
                        }
                    }
                    if let recorder = self.recorder, recorder.currentTime >= 120 { self.finishRecording(); timer.invalidate() }
                }
            }
            arm = timer; RunLoop.main.add(timer, forMode: .common)
        case .leftMouseDragged:
            hold.move(NSEvent.mouseLocation)
            if hold.origin == nil { attemptedTarget = false; trace("drag_cancelled"); arm?.invalidate(); if recorder != nil { cancel() } }
        case .leftMouseUp:
            localMouseReleased()
        case .keyDown:
            if event.keyCode == 53 { cancel() }
        default: break
        }
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func focusedElement() -> AXUIElement? {
        guard let value = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func focusBelongs(to editor: AXUIElement) -> Bool {
        var current = focusedElement()
        for _ in 0..<6 {
            guard let node = current else { return false }
            if CFEqual(node, editor) { return true }
            guard let raw = attribute(node, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
            current = (raw as! AXUIElement)
        }
        return false
    }
    private func prepareAccessibility() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return }
        diagnostic["application"] = app.bundleIdentifier ?? "unknown"
        if let requests = accessibilityRequests[app.processIdentifier] {
            diagnostic.merge(requests.mapValues { $0 as Any }) { _, value in value }
        }
        guard preparedApps.insert(app.processIdentifier).inserted else { return }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        // Chromium/CEF only exposes embedded editors after assistive technology
        // requests its tree. Unsupported attributes on native apps are harmless.
        diagnostic["manual_accessibility"] = AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue).rawValue
        diagnostic["enhanced_accessibility"] = AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue).rawValue
        accessibilityRequests[app.processIdentifier] = [
            "manual_accessibility": diagnostic["manual_accessibility"] as? Int32 ?? 0,
            "enhanced_accessibility": diagnostic["enhanced_accessibility"] as? Int32 ?? 0
        ]
        if let raw = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let window = raw as! AXUIElement
            AXUIElementSetMessagingTimeout(window, 0.1)
            _ = AXUIElementSetAttributeValue(window, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
    }
    private func recordDiagnostic(_ state: String, fileName: String = "dictation-status.json") {
        // Metadata only: never store field values, selected text, audio or transcripts.
        guard ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil else { return }
        var value = diagnostic
        value["state"] = state; value["updated"] = ISO8601DateFormatter().string(from: Date())
        let directory = ProcessInfo.processInfo.environment["TELOS_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telos")
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        let file = directory.appendingPathComponent(fileName)
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    private func trace(_ state: String) {
        if UserDefaults.standard.bool(forKey: "TelosDictationDiagnostics") { recordDiagnostic(state, fileName: "dictation-events.json") }
    }
    private func inputTarget() -> Target? {
        targetMessage = "Click inside an editable text field, then hold again"
        if let window = pressWindow {
            let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            guard let editor = Self.localEditor(in: window, at: point) else { return nil }
            return Target(editor: editor, element: nil, pid: ProcessInfo.processInfo.processIdentifier, range: editor.selectedRange(), axRange: nil)
        }
        guard AXIsProcessTrusted() else {
            targetMessage = "Enable Accessibility for Pico in System Settings, then hold again"
            return nil
        }
        guard let focused = focusedElement() else {
            targetMessage = "This app has not exposed its text field yet. Click the field, then hold again"
            diagnostic["reason"] = "no_focused_element"; return nil
        }
        var element = focused
        // A rich editor can focus an inner text node; its editable parent owns insertion.
        for _ in 0..<5 {
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role)
                || (role == kAXGroupRole && (attribute(element, "AXEditable") as? Bool) == true) { break }
            diagnostic["focused_role"] = role
            guard let raw = attribute(element, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
            let parent = raw as! AXUIElement
            let parentRole = attribute(parent, kAXRoleAttribute) as? String ?? ""
            if [kAXWindowRole, kAXApplicationRole].contains(parentRole) { break }
            element = parent
        }
        AXUIElementSetMessagingTimeout(element, 0.1)
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(element, kAXSubroleAttribute) as? String ?? ""
        diagnostic["role"] = role; diagnostic["subrole"] = subrole
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        var valueSettable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        let insertionRange = attribute(element, kAXSelectedTextRangeAttribute)
        var range = CFRange()
        let validRange: Bool
        if let insertionRange, CFGetTypeID(insertionRange) == AXValueGetTypeID() {
            let value = insertionRange as! AXValue
            validRange = AXValueGetType(value) == .cfRange && AXValueGetValue(value, .cfRange, &range) && range.location >= 0 && range.length >= 0
        } else { validRange = false }
        let editable = attribute(element, "AXEditable") as? Bool
        let readOnly = attribute(element, "AXReadOnly") as? Bool
        diagnostic["editable"] = editable; diagnostic["read_only"] = readOnly
        diagnostic["insertion_range"] = validRange
        diagnostic["writable_text"] = settable.boolValue; diagnostic["writable_value"] = valueSettable.boolValue
        guard DictationEditability.allows(role: role,
            enabled: attribute(element, kAXEnabledAttribute) as? Bool,
            editable: readOnly == true ? false : (editable ?? (readOnly == false ? true : nil)),
            secure: subrole == kAXSecureTextFieldSubrole,
            hasInsertionRange: validRange, writableText: settable.boolValue,
            writableValue: valueSettable.boolValue) else {
            diagnostic["reason"] = "not_editable"
            if subrole == kAXSecureTextFieldSubrole { targetMessage = "Voice typing is unavailable in password fields" }
            return nil
        }
        // Holding a button elsewhere must not record just because a text field retains focus.
        guard let mouse = CGEvent(source: nil)?.location else { return nil }
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(mouse.x), Float(mouse.y), &hit)
        var inside = false
        var hitRoles: [String] = []
        for _ in 0..<8 {
            guard let current = hit else { break }
            hitRoles.append(attribute(current, kAXRoleAttribute) as? String ?? "unknown")
            if CFEqual(current, element) { inside = true; break }
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            hit = (parent as! AXUIElement)
        }
        diagnostic["hit_roles"] = hitRoles
        guard inside else { diagnostic["reason"] = "pointer_outside_editor"; return nil }
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return Target(editor: nil, element: element, pid: pid, range: nil, axRange: attribute(element, kAXSelectedTextRangeAttribute))
    }
    private func beginRecording() -> Bool {
        attemptedTarget = true
        guard !busy, let input = inputTarget() else { return false }
        attemptedTarget = false
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show("Allow microphone access, then hold again", dismiss: true)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            recordDiagnostic("microphone_denied"); return true
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TelosVoice-\(UUID().uuidString).wav")
        do {
            let recording = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            guard recording.prepareToRecord(), recording.record() else { throw CocoaError(.fileWriteUnknown) }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            target = input; audioURL = url; recorder = recording; busy = true
            NSSound(named: "Tink")?.play()
            show("Listening… Release to insert text")
            recordDiagnostic("recording")
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishRecording()
            }
        } catch { try? FileManager.default.removeItem(at: url); show("Microphone could not start", dismiss: true); recordDiagnostic("microphone_failed") }
        return true
    }
    private func finishRecording() {
        guard let recorder, let audioURL else { return }
        let length = recorder.currentTime; recorder.stop(); self.recorder = nil
        deadline?.cancel(); deadline = nil
        guard length > 0.3 else { cancel(); return }
        let useCloud = DictationBailianAccount.enabled
        let polish = UserDefaults.standard.object(forKey: "TelosVoicePolish") == nil || UserDefaults.standard.bool(forKey: "TelosVoicePolish")
        diagnostic["recognizer"] = useCloud ? "bailian" : "local"
        recognition.transcribe(audioURL, useCloud: useCloud, polish: polish, stage: { [weak self] stage in
            guard let self else { return }
            switch stage {
            case .cloud: self.show("Transcribing with Bailian…")
            case .local: self.show("Transcribing on your Mac…")
            case .polishing: self.show("Tidying your words…")
            case .fallback(let error):
                let error = error as NSError
                self.diagnostic["cloud_error_domain"] = error.domain
                self.diagnostic["cloud_error_code"] = error.code
                self.diagnostic["recognizer"] = "local_fallback"
                self.show("Bailian unavailable — recognizing on your Mac…")
            }
            self.recordDiagnostic("transcribing")
        }, completion: { [weak self] value in
            guard let self else { return }
            if let text = value["text"] as? String, !text.isEmpty {
                self.recordDiagnostic("recognized")
                self.deliver(text)
            } else {
                self.recordDiagnostic(value["error"] == nil ? "no_speech" : "recognition_failed")
                self.show(value["error"] as? String ?? "No speech detected", dismiss: true)
            }
            self.cleanupAudio(); self.busy = false; self.deadline?.cancel(); self.deadline = nil
        })
        guard busy else { return }
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            self?.engine.stop(); self?.cancel(); self?.show("Transcription timed out. Please try again", dismiss: true)
        }
    }
    func localMouseReleased() {
        hold.cancel(); arm?.invalidate(); arm = nil
        if recorder != nil { finishRecording() }
        else if attemptedTarget && !busy && !insertionPending {
            recordDiagnostic("target_unavailable")
            show(targetMessage, dismiss: true)
        } else { trace("released") }
        attemptedTarget = false
    }
    private func deliver(_ text: String) {
        guard let target else { return }
        if let editor = target.editor, editor.window?.firstResponder === editor, editor.selectedRange() == target.range {
            let range = editor.selectedRange()
            let expected = DictationInsertion.expected(before: editor.string, range: CFRange(location: range.location, length: range.length), text: text)
            editor.insertText(text, replacementRange: range)
            if DictationInsertion.confirmed(expected: expected, actual: editor.string) { show("Inserted", dismiss: true) }
            else {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                show("Text copied — insertion not confirmed", dismiss: true)
            }
            return
        }
        guard let element = target.element, focusBelongs(to: element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid,
              target.axRange.map({ saved in attribute(element, kAXSelectedTextRangeAttribute).map { CFEqual(saved, $0) } ?? false }) ?? true else {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            show("Focus changed — text copied", dismiss: true); return
        }
        let before = attribute(element, kAXValueAttribute) as? String
        var selectedRange: CFRange?
        if let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() {
            let value = raw as! AXValue
            var range = CFRange()
            if AXValueGetValue(value, .cfRange, &range) { selectedRange = range }
        }
        let expected = DictationInsertion.expected(before: before, range: selectedRange, text: text)
        // Real Command-V is handled by native, browser and Electron editors. A successful
        // AX setter or posted Unicode event does not prove that an app changed its document.
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else {
            show("Could not copy transcript", dismiss: true); return
        }
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            show("Text copied — press ⌘V to insert", dismiss: true); return
        }
        // Recheck focus immediately before posting; never activate or redirect another app.
        guard focusBelongs(to: element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            show("Focus changed — text copied", dismiss: true); return
        }
        insertionPending = true; insertionID = UUID(); let token = insertionID
        down.flags = .maskCommand; up.flags = .maskCommand
        TelosKeyboardEvent.markDictationPaste(down); TelosKeyboardEvent.markDictationPaste(up)
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.insertionID == token else { return }
                let actual = self.attribute(element, kAXValueAttribute) as? String
                if DictationInsertion.confirmed(expected: expected, actual: actual) {
                    self.insertionPending = false; self.show("Inserted", dismiss: true); return
                }
            }
            guard let self, self.insertionID == token else { return }
            self.insertionPending = false
            // No retry: an editor may have pasted successfully without exposing its value.
            self.show("Text copied — paste not confirmed", dismiss: true)
        }
    }
    private func show(_ message: String, dismiss: Bool = false) {
        hudGeneration = UUID(); let generation = hudGeneration
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 56), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Pico Voice Typing"
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .statusBar
            panel.ignoresMouseEvents = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let backdrop = NSVisualEffectView(frame: panel.contentView!.bounds); backdrop.material = .hudWindow; backdrop.state = .active
            backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 16; backdrop.layer?.masksToBounds = true
            panel.contentView = backdrop; hud = panel
        }
        guard let hud else { return }
        hud.contentView?.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: message); label.font = .systemFont(ofSize: 13); label.alignment = .center
        label.lineBreakMode = .byWordWrapping; label.maximumNumberOfLines = 2
        label.frame = NSRect(x: 8, y: 8, width: 404, height: 40); hud.contentView?.addSubview(label)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame { hud.setFrameOrigin(NSPoint(x: frame.midX - 210, y: frame.minY + 40)) }
        hud.orderFrontRegardless()
        if dismiss { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.hudGeneration == generation { self?.hud?.orderOut(nil) } } }
    }
    private func cleanupAudio() { if let audioURL { try? FileManager.default.removeItem(at: audioURL) }; audioURL = nil; target = nil }
    func cancel() {
        recognition.cancel()
        cloudDictation.cancel()
        attemptedTarget = false
        insertionID = UUID(); insertionPending = false
        hold.cancel(); arm?.invalidate(); arm = nil; deadline?.cancel(); deadline = nil
        if !companionBusy { if busy && recorder == nil { engine.stop() } else { engine.cancel() } }
        recorder?.stop(); recorder = nil
        cleanupAudio(); busy = false; hud?.orderOut(nil)
    }
    func stop() {
        cancel(); engine.stop()
        permissionTimer?.invalidate(); permissionTimer = nil; lastTrusted = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }; globalMonitor = nil
    }
}
