import Foundation

enum TaskExecutionPolicy {
    static let preference = "TelosAutomaticExecution"

    static func requestOptions(feedID: String?, voiceRequestID: String?, defaults: UserDefaults = .standard) -> [String: Bool] {
        let automatic = defaults.object(forKey: preference) == nil || defaults.bool(forKey: preference)
        // Speech and typing are equivalent task entry points. Background feeds
        // keep their separate, restricted tool catalog.
        return ["auto_approve": automatic && feedID == nil, "voice": voiceRequestID != nil]
    }
}
