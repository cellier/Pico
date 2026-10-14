import Foundation
@main struct BailianSettingsTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = BailianSettings(directory: directory)
        let absent = try settings.load(); precondition(absent == nil)
        try ProviderSettings(directory: directory).save(apiKey: "deepseek-test-only")
        let deepseekBefore = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        try settings.save(region: "cn-beijing", workspace: " ws-test ", apiKey: " test-only-key ")
        let reloaded = try BailianSettings(directory: directory).load()!
        precondition(reloaded.apiKey == "test-only-key" && reloaded.identity == "cn-beijing:ws-test")
        let permissions = try FileManager.default.attributesOfItem(atPath: settings.file.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        let good = try Data(contentsOf: settings.file)
        do { try settings.save(region: "cn-beijing", workspace: "ws-test", apiKey: "bad key"); fatalError() } catch {}
        do { try settings.save(region: "bad", workspace: "ws-test", apiKey: "x"); fatalError() } catch {}
        do { try settings.save(region: "cn-beijing", workspace: "bad/host", apiKey: "x"); fatalError() } catch {}
        let afterInvalid = try Data(contentsOf: settings.file); precondition(afterInvalid == good)
        try settings.save(region: "ap-southeast-1", workspace: "ws-new", apiKey: "replacement")
        let replaced = try settings.load()!; precondition(replaced.apiKey == "replacement")
        try settings.save(region: "ap-southeast-1", workspace: "ws-new", apiKey: "")
        let cleared = try settings.load()!; precondition(cleared.apiKey.isEmpty)
        let deepseekAfter = try Data(contentsOf: directory.appendingPathComponent("config.json")); precondition(deepseekBefore == deepseekAfter)
        try Data("corrupt".utf8).write(to: settings.file)
        do { try settings.save(region: "cn-beijing", workspace: "ws-test", apiKey: "x"); fatalError() } catch {}
        let corrupt = try Data(contentsOf: settings.file); precondition(corrupt == Data("corrupt".utf8))
        print("PASS: persistent reload, account validation, replace/clear, owner-only permissions, DeepSeek preservation and corrupt-file protection")
    }
}
