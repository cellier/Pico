import Foundation
@main struct ProviderSettingsTests {
    static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = ProviderSettings(directory: dir)
        check(try settings.apiKey().isEmpty)
        try settings.save(apiKey: " test-key ")
        check(try settings.apiKey() == "test-key")
        let file = dir.appendingPathComponent("config.json")
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        value["model"] = "existing-model"; value["other"] = true
        try JSONSerialization.data(withJSONObject: value).write(to: file)
        try settings.save(apiKey: "replacement")
        value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        precondition(value["model"] as? String == "existing-model" && value["other"] as? Bool == true)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        try settings.save(apiKey: "")
        check(try settings.apiKey().isEmpty)
        try Data("broken".utf8).write(to: file)
        do { try settings.save(apiKey: "replacement"); fatalError("Must preserve malformed config") } catch {}
        check(try Data(contentsOf: file) == Data("broken".utf8))
        print("PASS: load, save, clear, permissions, preserve settings and corrupt-file protection")
    }
}
