import AppKit
import SwiftUI
import Carbon

/// Only the most recent key is rendered. No keystroke history is retained.
enum KeyDisplayLabel {
    static let preference = "TelosShowKeystrokes"
    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: preference) == nil || defaults.bool(forKey: preference)
    }
    static func modifiers(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }
    static func key(code: UInt16, characters: String?) -> String? {
        let special: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "⌫", 53: "Esc", 57: "Caps Lock",
            65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "-", 81: "=",
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
            114: "Help", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4", 119: "End",
            120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        if let value = special[code] { return value }
        guard let characters, characters.count == 1,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !($0.value >= 0xF700 && $0.value <= 0xF8FF) }) else { return nil }
        return characters.uppercased()
    }
    static func text(code: UInt16, characters: String?, flags: NSEvent.ModifierFlags, secure: Bool) -> String? {
        guard !secure, let key = key(code: code, characters: characters) else { return nil }
        return modifiers(flags) + key
    }
}

/// Releasing a shortcut's modifiers must not replace the chord before viewers can read it.
struct KeyDisplayHold {
    private var held: NSEvent.ModifierFlags = []
    private var keys: Set<UInt16> = []
    private(set) var functionPressed = false
    private var chord = false
    var isHeld: Bool { !keys.isEmpty || !held.isEmpty || functionPressed }
    mutating func keyPressed(_ code: UInt16, flags: NSEvent.ModifierFlags) {
        keys.insert(code)
        held = flags.intersection([.control, .option, .shift, .command])
        chord = true
    }
    mutating func keyReleased(_ code: UInt16) { keys.remove(code) }
    mutating func functionChanged(_ pressed: Bool) { functionPressed = pressed }
    mutating func modifiersChanged(_ flags: NSEvent.ModifierFlags) -> String? {
        let current = flags.intersection([.control, .option, .shift, .command])
        let pressed = current.rawValue & ~held.rawValue != 0
        held = current
        if pressed && keys.isEmpty { chord = false }
        return chord ? nil : KeyDisplayLabel.modifiers(current)
    }
}

private final class KeyDisplayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct KeyDisplayHUD: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 32, weight: .semibold, design: .rounded))
            .foregroundStyle(.white).padding(.horizontal, 26).padding(.vertical, 12)
            .background(Color.black.opacity(0.80), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.white.opacity(0.16), lineWidth: 1))
            .padding(5)
    }
}

@MainActor final class KeyDisplayController: ObservableObject {
    static let shared = KeyDisplayController()
    @Published private(set) var enabled: Bool
    @Published private(set) var permissionGranted = false
    @Published private(set) var monitoring = false
    @Published private(set) var secureInput = false
    private let defaults: UserDefaults
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var hideTimer: Timer?
    private var panel: KeyDisplayPanel?
    private var hold = KeyDisplayHold()
    private var ticks = 0
    private let requestedKey = "TelosKeyDisplayPermissionRequested"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = KeyDisplayLabel.enabled(in: defaults)
    }
    var status: String {
        if !enabled { return "Keystroke display is off." }
        if !permissionGranted { return "Input Monitoring permission is required." }
        if secureInput { return "Paused during secure input." }
        return monitoring ? "Ready · keys appear at the bottom of your screen." : "Could not start. Check permission or restart Telos."
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.checkSecureInput()
                self.ticks += 1
                if self.ticks % 4 == 0 { self.refresh() }
            }
        }
        self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        if enabled && !permissionGranted && !defaults.bool(forKey: requestedKey) { requestPermission(openSettings: false) }
    }
    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: KeyDisplayLabel.preference)
        enabled = value
        if !value { stopMonitoring() }
        else {
            refresh()
            if !permissionGranted { requestPermission(openSettings: true) }
        }
    }
    func requestPermission(openSettings: Bool = true) {
        defaults.set(true, forKey: requestedKey)
        _ = CGRequestListenEventAccess()
        refresh()
        if openSettings && !permissionGranted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    func refresh() {
        let allowed = CGPreflightListenEventAccess()
        if permissionGranted != allowed { permissionGranted = allowed }
        guard enabled && allowed else { stopMonitoring(); return }
        checkSecureInput()
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                         options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                MainActor.assumeIsolated {
                    Unmanaged<KeyDisplayController>.fromOpaque(context).takeUnretainedValue().receive(type, event)
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: context), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return }
        self.tap = tap; self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        monitoring = true
    }
    private func checkSecureInput() {
        let secure = IsSecureEventInputEnabled() || (NSApp.keyWindow?.firstResponder as? NSTextView)?.delegate is NSSecureTextField
        if secureInput != secure { secureInput = secure }
        if secure { hide(); hold = KeyDisplayHold() }
    }
    private func receive(_ type: CGEventType, _ event: CGEvent) {
        guard enabled && permissionGranted else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            hide(); hold = KeyDisplayHold()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }; return
        }
        guard TelosKeyboardEvent.shouldDisplay(event) else { return }
        checkSecureInput()
        guard !secureInput, let keyEvent = NSEvent(cgEvent: event) else { return }
        if type == .flagsChanged {
            if keyEvent.keyCode == 57 {
                show(keyEvent.modifierFlags.contains(.capsLock) ? "Caps Lock On" : "Caps Lock Off")
            } else if keyEvent.keyCode == 63 {
                hold.functionChanged(keyEvent.modifierFlags.contains(.function))
                if hold.functionPressed { show("fn") }
            } else if let text = hold.modifiersChanged(keyEvent.modifierFlags) {
                if !text.isEmpty { show(text) }
            }
        } else if type == .keyDown {
            hold.keyPressed(keyEvent.keyCode, flags: keyEvent.modifierFlags)
            if let text = KeyDisplayLabel.text(code: keyEvent.keyCode, characters: keyEvent.charactersIgnoringModifiers,
                                               flags: keyEvent.modifierFlags, secure: false) {
                show((hold.functionPressed ? "fn " : "") + text)
            }
        } else if type == .keyUp {
            hold.keyReleased(keyEvent.keyCode)
        }
        updateHideTimer()
    }
    private func show(_ text: String) {
        hideTimer?.invalidate(); hideTimer = nil
        let host = NSHostingView(rootView: KeyDisplayHUD(text: text))
        let size = host.fittingSize
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let panel: KeyDisplayPanel
        if let existing = self.panel { panel = existing }
        else {
            panel = KeyDisplayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Telos Keystrokes"; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.level = .screenSaver; panel.hasShadow = false; panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.sharingType = .readOnly
            self.panel = panel
        }
        panel.contentView = host
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 42, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
    private func updateHideTimer() {
        if hold.isHeld {
            hideTimer?.invalidate(); hideTimer = nil
            return
        }
        guard hideTimer == nil, panel?.isVisible == true else { return }
        let timer = Timer(timeInterval: 1.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.hold.isHeld else { return }
                self.hide()
            }
        }
        hideTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    private func hide() {
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil); panel?.contentView = nil
    }
    private func stopMonitoring() {
        hide()
        hold = KeyDisplayHold()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
        if monitoring { monitoring = false }
    }
    func stop() { timer?.invalidate(); timer = nil; stopMonitoring() }
}

struct KeyDisplaySettingsView: View {
    @ObservedObject private var controller = KeyDisplayController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show keystrokes", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
                .font(.system(size: 14, weight: .medium)).accessibilityIdentifier("showKeystrokes")
            Text("Show pressed keys and shortcuts at the bottom of the current screen, including in other apps. Stays visible while held, then disappears 1.6 seconds after all keys are released. Nothing is recorded; secure input is excluded.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(controller.status).font(.system(size: 12)).foregroundStyle(.secondary)
                .accessibilityIdentifier("keystrokeDisplayStatus")
            if controller.enabled && !controller.permissionGranted {
                Button("Enable Input Monitoring") { controller.requestPermission() }
            }
        }.onAppear { controller.refresh() }
    }
}
