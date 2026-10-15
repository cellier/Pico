import Foundation

/// Shares the local configuration used by the task worker and voice polishing.
struct ProviderSettings {
    enum Error: Swift.Error { case invalidKey }
    let directory: URL
    private var file: URL { directory.appendingPathComponent("config.json") }
    private func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }
    func apiKey() throws -> String { try read()["api_key"] as? String ?? "" }
    /// The OpenAI-compatible chat endpoint, model and key the worker uses.
    func chatEndpoint() throws -> (url: URL, model: String, apiKey: String)? {
        let value = try read()
        guard let key = value["api_key"] as? String, !key.isEmpty,
              let url = URL(string: ((value["base_url"] as? String) ?? "https://api.deepseek.com").trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        return (url, value["model"] as? String ?? "deepseek-flash", key)
    }
    func save(apiKey: String) throws {
        var value = try read()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.contains(where: { $0.isWhitespace }) else { throw Error.invalidKey }
        value["api_key"] = key
        if value["base_url"] == nil { value["base_url"] = "https://api.deepseek.com" }
        if value["model"] == nil { value["model"] = "deepseek-flash" }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
