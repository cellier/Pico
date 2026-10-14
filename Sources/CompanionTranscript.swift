import Foundation

enum CompanionTranscript {
    static func read(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > 1, text.count <= 3000, !text.contains("\0") else { return nil }
        return text
    }
}
