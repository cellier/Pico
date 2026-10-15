import CoreGraphics

/// Identify only Telos's generated paste events, leaving real keystrokes visible.
enum TelosKeyboardEvent {
    private static let dictationPaste: Int64 = 0x54454C4F535650
    static func markDictationPaste(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: dictationPaste)
    }
    /// Other generated shortcuts, such as the ⌘C that reads a selection, are hidden the same way.
    static func markSynthetic(_ event: CGEvent) { markDictationPaste(event) }
    static func shouldDisplay(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) != dictationPaste
    }
}
