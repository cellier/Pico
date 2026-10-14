import Cocoa
func L(_ a: String, _ b: String) -> String { a }
func log(_ text: String) {}
func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS " + name) }
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let file = folder.appendingPathComponent("bailian.json")
let legacy = BailianConfig(region: "cn-beijing", workspace: "legacy-workspace")
var legacyReads = 0
func readLegacy(_ account: String) -> String? { legacyReads += 1; return "legacy-test-key" }
func load() throws -> BailianCredentials.Account {
    try BailianCredentials.load(at: file, legacy: legacy, legacyRead: readLegacy)
}
func write(_ key: String, region: String = "ap-southeast-1") throws {
    try JSONEncoder().encode(BailianCredentials.Account(region: region, workspace: "shared-workspace", apiKey: key)).write(to: file, options: .atomic)
}
let absent = try load()
check(absent.apiKey == "legacy-test-key" && legacyReads == 1, "Legacy is used only when shared file is absent")
try write("saved-test-key")
let saved = try load()
check(saved.apiKey == "saved-test-key" && saved.config.account == "ap-southeast-1:shared-workspace" && legacyReads == 1, "Shared region, workspace and key are one account snapshot")
try write("updated-test-key")
check(try load().apiKey == "updated-test-key", "Saved account is refreshed between requests")
for invalid in ["", "invalid key"] {
    try write(invalid)
    do { _ = try load(); fatalError("Invalid shared key accepted") } catch {}
}
try write("test-key", region: "invalid-region")
do { _ = try load(); fatalError("Invalid shared region accepted") } catch {}
try Data("{invalid".utf8).write(to: file)
do { _ = try load(); fatalError("Corrupt shared file accepted") } catch {}
check(legacyReads == 1, "Empty, malformed or invalid shared account never revives old credentials")
let directoryFile = folder.appendingPathComponent("folder")
try FileManager.default.createDirectory(at: directoryFile, withIntermediateDirectories: true)
do { _ = try BailianCredentials.load(at: directoryFile, legacy: legacy, legacyRead: readLegacy); fatalError("Unreadable shared path accepted") } catch {}
check(legacyReads == 1, "Unreadable shared file never uses legacy credentials")

func pump(until condition: () -> Bool, timeout: TimeInterval = 2) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
    check(condition(), "Async operation completed in time")
}
let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
let asr = CloudRecognition(credentials: {
    check(!Thread.isMainThread, "Credential preparation stays off UI thread")
    started.signal(); release.wait()
    throw URLError(.userAuthenticationRequired)
})
var callback = false
let began = Date()
asr.transcribe(folder.appendingPathComponent("unused.wav")) { result in
    check(Thread.isMainThread, "Recognition completion delivered on UI thread")
    if case .failure(let error) = result { check((error as NSError).code == URLError.userAuthenticationRequired.rawValue, "Credential failure is preserved") } else { fatalError("Expected credential failure") }
    callback = true
}
check(Date().timeIntervalSince(began) < 0.1 && !callback, "Starting recognition does not block on credentials")
check(started.wait(timeout: .now() + 2) == .success, "Background preparation starts")
release.signal(); pump(until: { callback })
let cancelStarted = DispatchSemaphore(value: 0), cancelRelease = DispatchSemaphore(value: 0), cancelFinished = DispatchSemaphore(value: 0)
let cancellable = CloudRecognition(credentials: {
    cancelStarted.signal(); cancelRelease.wait(); defer { cancelFinished.signal() }
    throw URLError(.userAuthenticationRequired)
})
var stale = false
cancellable.transcribe(folder.appendingPathComponent("unused.wav")) { _ in stale = true }
check(cancelStarted.wait(timeout: .now() + 2) == .success, "Cancellable preparation starts")
cancellable.cancel(); cancelRelease.signal()
check(cancelFinished.wait(timeout: .now() + 2) == .success, "Cancelled preparation finishes")
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(!stale, "Cancel suppresses stale preparation completion")
print("No real credentials, network requests, Keychain access or playback used.")
