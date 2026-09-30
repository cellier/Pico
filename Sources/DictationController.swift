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
        guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              !secure, enabled != false, editable != false, (hasInsertionRange || editable == true) else { return false }
        return writableText || writableValue || editable == true
    }
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
    private var audioURL: URL?
    private var target: Target?
    private var hud: NSPanel?
    private var hudGeneration = UUID()
    private var busy = false
    private var insertionPending = false
    private var insertionID = UUID()
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
        guard trusted != lastTrusted || (trusted && globalMonitor == nil) else { return }
        lastTrusted = trusted
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        guard trusted else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .keyDown]) { [weak self] event in
            self?.handle(event, local: false)
        }
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
        guard enabled, UserDefaults.standard.object(forKey: "TelosVoiceTypingEnabled") == nil || UserDefaults.standard.bool(forKey: "TelosVoiceTypingEnabled") else { cancel(); return }
        switch event.type {
        case .leftMouseDown:
            guard !busy, !insertionPending else { return }
            pressWindow = local ? event.window : nil
            arm?.invalidate(); hold.begin(NSEvent.mouseLocation)
            let started = Date(); var activated = false
            let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { timer.invalidate(); return }
                    guard NSEvent.pressedMouseButtons & 1 != 0 else { self.localMouseReleased(); return }
                    self.hold.move(NSEvent.mouseLocation)
                    guard self.hold.origin != nil else { self.cancel(); return }
                    if !activated && Date().timeIntervalSince(started) >= 0.55 {
                        activated = true; self.beginRecording()
                    }
                    if let recorder = self.recorder, recorder.currentTime >= 120 { self.finishRecording(); timer.invalidate() }
                }
            }
            arm = timer; RunLoop.main.add(timer, forMode: .common)
        case .leftMouseDragged:
            hold.move(NSEvent.mouseLocation)
            if hold.origin == nil { arm?.invalidate(); if recorder != nil { cancel() } }
        case .leftMouseUp:
            hold.cancel(); arm?.invalidate(); arm = nil
            if recorder != nil { finishRecording() }
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
    private func inputTarget() -> Target? {
        if let window = pressWindow {
            let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            guard let editor = Self.localEditor(in: window, at: point) else { return nil }
            return Target(editor: editor, element: nil, pid: ProcessInfo.processInfo.processIdentifier, range: editor.selectedRange(), axRange: nil)
        }
        guard AXIsProcessTrusted(), let element = focusedElement(),
              let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              (attribute(element, kAXSubroleAttribute) as? String) != kAXSecureTextFieldSubrole else { return nil }
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
        guard DictationEditability.allows(role: role,
            enabled: attribute(element, kAXEnabledAttribute) as? Bool,
            editable: attribute(element, "AXEditable") as? Bool,
            secure: (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole,
            hasInsertionRange: validRange, writableText: settable.boolValue,
            writableValue: valueSettable.boolValue) else { return nil }
        // Holding a button elsewhere must not record just because a text field retains focus.
        let mouse = NSEvent.mouseLocation
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(mouse.x), Float(screenHeight - mouse.y), &hit)
        var inside = false
        for _ in 0..<8 {
            guard let current = hit else { break }
            if CFEqual(current, element) { inside = true; break }
            guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            hit = (parent as! AXUIElement)
        }
        guard inside else { return nil }
        var pid: pid_t = 0; AXUIElementGetPid(element, &pid)
        guard pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        return Target(editor: nil, element: element, pid: pid, range: nil, axRange: attribute(element, kAXSelectedTextRangeAttribute))
    }
    private func beginRecording() {
        guard !busy, let input = inputTarget() else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            show("Allow microphone access, then hold again", dismiss: true)
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
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
            deadline = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishRecording()
            }
        } catch { try? FileManager.default.removeItem(at: url); show("Microphone could not start", dismiss: true) }
    }
    private func finishRecording() {
        guard let recorder, let audioURL else { return }
        let length = recorder.currentTime; recorder.stop(); self.recorder = nil
        deadline?.cancel(); deadline = nil
        guard length > 0.3 else { cancel(); return }
        show("Transcribing on your Mac…")
        let polish = UserDefaults.standard.object(forKey: "TelosVoicePolish") == nil || UserDefaults.standard.bool(forKey: "TelosVoicePolish")
        engine.transcribe(audioURL, polish: polish) { [weak self] value in
            guard let self else { return }
            if value["stage"] as? String == "polishing" { self.show("Tidying your words…"); return }
            if let text = value["text"] as? String, !text.isEmpty { self.deliver(text) }
            else { self.show(value["error"] as? String ?? "No speech detected", dismiss: true) }
            self.cleanupAudio(); self.busy = false; self.deadline?.cancel(); self.deadline = nil
        }
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
        guard let element = target.element, let focused = focusedElement(), CFEqual(element, focused),
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
        guard let current = focusedElement(), CFEqual(current, element),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid else {
            show("Focus changed — text copied", dismiss: true); return
        }
        insertionPending = true; insertionID = UUID(); let token = insertionID
        down.flags = .maskCommand; up.flags = .maskCommand
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
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .floating
            panel.ignoresMouseEvents = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let backdrop = NSVisualEffectView(frame: panel.contentView!.bounds); backdrop.material = .hudWindow; backdrop.state = .active
            backdrop.wantsLayer = true; backdrop.layer?.cornerRadius = 16; backdrop.layer?.masksToBounds = true
            panel.contentView = backdrop; hud = panel
        }
        guard let hud else { return }
        hud.contentView?.subviews.forEach { $0.removeFromSuperview() }
        let label = NSTextField(labelWithString: message); label.font = .systemFont(ofSize: 13); label.alignment = .center
        label.frame = NSRect(x: 8, y: 13, width: 324, height: 20); hud.contentView?.addSubview(label)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame { hud.setFrameOrigin(NSPoint(x: frame.midX - 170, y: frame.minY + 40)) }
        hud.orderFrontRegardless()
        if dismiss { DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.hudGeneration == generation { self?.hud?.orderOut(nil) } } }
    }
    private func cleanupAudio() { if let audioURL { try? FileManager.default.removeItem(at: audioURL) }; audioURL = nil; target = nil }
    func cancel() {
        insertionID = UUID(); insertionPending = false
        hold.cancel(); arm?.invalidate(); arm = nil; deadline?.cancel(); deadline = nil
        if busy && recorder == nil { engine.stop() } else { engine.cancel() }
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
