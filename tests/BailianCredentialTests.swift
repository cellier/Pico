import Foundation
import Security

@main struct BailianCredentialTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = BailianSettings(directory: directory)
        var requested: [String] = []
        func checkQuery(_ query: CFDictionary) -> String {
            var allowed = DarwinBoolean(true)
            precondition(SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess && !allowed.boolValue)
            let q = query as NSDictionary
            precondition(q[kSecUseAuthenticationUI] as? String == kSecUseAuthenticationUIFail as String)
            precondition(q[kSecAttrAccount] as? String == "test-account")
            let service = q[kSecAttrService] as! String
            requested.append(service)
            return service
        }
        let preferred = BailianCredentialStore.read(account: "test-account", settings: settings) { q, result in
            _ = checkQuery(q); result?.pointee = Data("test-only-key".utf8) as CFData; return errSecSuccess
        }
        precondition(preferred == "test-only-key" && requested == [BailianCredentialStore.service])
        requested = []
        let denied = BailianCredentialStore.read(account: "test-account", settings: settings) { q, _ in
            _ = checkQuery(q); return errSecInteractionNotAllowed
        }
        precondition(denied == nil && requested.count == 1, "denied private key cannot silently fall back")
        requested = []
        let legacy = BailianCredentialStore.read(account: "test-account", settings: settings) { q, result in
            let service = checkQuery(q)
            if service == BailianCredentialStore.service { return errSecItemNotFound }
            result?.pointee = Data("legacy-test-key".utf8) as CFData; return errSecSuccess
        }
        precondition(legacy == "legacy-test-key" && requested.count == 2)
        requested = []
        let lockedLegacy = BailianCredentialStore.read(account: "test-account", settings: settings) { q, _ in
            checkQuery(q) == BailianCredentialStore.service ? errSecItemNotFound : errSecAuthFailed
        }
        precondition(lockedLegacy == nil && requested.count == 2)
        precondition(BailianCredentialStore.service != BailianCredentialStore.legacyService)
        BailianCredentialStore.useForSession("session-test-key", account: "session-test-account")
        precondition(BailianCredentialStore.read(account: "session-test-account", settings: settings) { _, _ in
            preconditionFailure("session key must not access Keychain")
        } == "session-test-key")
        try settings.save(region: "cn-beijing", workspace: "ws-test", apiKey: "persistent-test-key")
        precondition(BailianCredentialStore.read(account: "cn-beijing:ws-test", settings: settings) { _, _ in
            preconditionFailure("saved key must never access Keychain")
        } == "persistent-test-key")
        try settings.save(region: "cn-beijing", workspace: "ws-test", apiKey: "")
        precondition(BailianCredentialStore.read(account: "cn-beijing:ws-test", settings: settings) { _, _ in
            preconditionFailure("removed key must not resurrect legacy credentials")
        } == nil)
        print("PASS: private credential preferred; process-level authentication UI disabled during reads; denied private credential never falls back; legacy credential only read when private entry absent. No real secrets read or written.")
    }
}
