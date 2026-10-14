import CoreGraphics

/// Identify only Telos's generated paste events, leaving real keystrokes visible.
enum TelosKeyboardEvent {
    private static let dictationPaste: Int64 = 0x54454C4F535650
    static func markDictationPaste(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: dictationPaste)
    }
    static func shouldDisplay(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) != dictationPaste
    }
}
