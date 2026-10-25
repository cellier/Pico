import AppKit

/// Interface sounds, played only when "Play user interface sound effects" is on.
@MainActor enum PicoSounds {
    /// The system's own Messages "sent" sound, read from macOS at runtime (not bundled);
    /// Pop when a future macOS moves it.
    private static let sent: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/SentMessage.caf"
        let sound = NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop")
        sound?.volume = 0.6
        return sound
    }()

    static func messageSent() {
        guard interfaceSoundsEnabled, ProcessInfo.processInfo.environment["TELOS_PREVIEW"] == nil, let sent else { return }
        sent.stop(); sent.play()
    }

    private static var interfaceSoundsEnabled: Bool {
        // Absent means the default, which is on.
        UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }
}
