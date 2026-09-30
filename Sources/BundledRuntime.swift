import Foundation

/// Release paths are relative to the app; development builds can keep explicit interpreters.
enum BundledRuntime {
    static func python(speech: Bool = false, bundle: Bundle = .main) -> String? {
        let key = speech ? "TelosSpeechPython" : "TelosPython"
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        if value.hasPrefix("/") { return value }
        return bundle.resourceURL?.appendingPathComponent(value).path
    }
}
