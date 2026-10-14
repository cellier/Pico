import Foundation
import Darwin

/// Same local persistence model as ProviderSettings, in a separate file so saving
/// either provider cannot overwrite the other provider's configuration.
struct BailianSettings {
    struct Account: Codable {
        var region: String
        var workspace: String
        var apiKey: String
        var identity: String { region + ":" + workspace }
    }
    enum Error: Swift.Error { case invalidAccount, invalidKey }
    let directory: URL
    static var live: Self {
        Self(directory: ProcessInfo.processInfo.environment["TELOS_DATA_DIR"].map { URL(fileURLWithPath: $0) }
             ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Telos"))
    }
    var file: URL { directory.appendingPathComponent("bailian.json") }
    func load() throws -> Account? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(Account.self, from: Data(contentsOf: file))
    }
    func save(region: String, workspace: String, apiKey: String) throws {
        // Do not overwrite an unreadable or corrupt saved configuration.
        _ = try load()
        let workspace = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DictationBailianAccount(region: region, workspace: workspace).endpoint != nil else { throw Error.invalidAccount }
        guard !key.contains(where: { $0.isWhitespace }) else { throw Error.invalidKey }
        let account = Account(region: region, workspace: workspace, apiKey: key)
        let bytes = try JSONEncoder().encode(account)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".bailian-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
