import AppKit
import SwiftUI
import Security

/// Persistent Telos settings take priority. Legacy Keychain access is migration-only and never prompts.
enum BailianCredentialStore {
    // Legacy macOS login-keychain ACL dialogs do not honor every SecItem UI hint.
    // Keep optional Security interaction disabled for this process, including writes.
    private static let accessLock = NSRecursiveLock()
    private static var sessionKeys: [String: String] = [:]
    static func useForSession(_ key: String, account: String) {
        accessLock.lock(); defer { accessLock.unlock() }
        sessionKeys[account] = key
    }
    private static func withoutAuthenticationUI<T>(_ denied: T, _ operation: () -> T) -> T {
        accessLock.lock()
        defer { accessLock.unlock() }
        guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return denied }
        return operation()
    }
    static let service = "com.telos.mac.bailian"
    static let legacyService = "local.original.sprout.bailian-tts"
    static func query(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    static func read(account: String, settings: BailianSettings = .live, copy: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching) -> String? {
        accessLock.lock(); defer { accessLock.unlock() }
        do {
            if let saved = try settings.load() { return saved.identity == account && !saved.apiKey.isEmpty ? saved.apiKey : nil }
        } catch { return nil }
        if let key = sessionKeys[account] { return key }
        return withoutAuthenticationUI(nil) {
        for service in [service, legacyService] {
            var q = query(service: service, account: account)
            q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = copy(q as CFDictionary, &value)
            if status == errSecSuccess {
                guard let bytes = value as? Data else { return nil }
                return String(data: bytes, encoding: .utf8)
            }
            // A saved but inaccessible Telos key must not silently select another credential.
            if status != errSecItemNotFound { return nil }
        }
        return nil
        }
    }
    static func save(_ key: String, account: String) -> OSStatus {
        return withoutAuthenticationUI(errSecInteractionNotAllowed) {
        var item = query(service: service, account: account)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecAttrLabel as String] = "Pico · Bailian"
        let result = SecItemAdd(item as CFDictionary, nil)
        if result == errSecSuccess { sessionKeys.removeValue(forKey: account); return result }
        guard result == errSecDuplicateItem else { return result }
        let updated = SecItemUpdate(query(service: service, account: account) as CFDictionary,
                                    [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if updated == errSecSuccess { sessionKeys.removeValue(forKey: account) }
        return updated
        }
    }
}

/// Shared by Telos Settings and the meeting account shortcut.
struct BailianSettingsView: View {
    var settings: BailianSettings = .live
    @State private var region = "cn-beijing"
    @State private var workspace = ""
    @State private var key = ""
    @State private var message: String?
    @State private var failed = false
    @State private var loaded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bailian API Key").font(.system(size: 14, weight: .medium))
            SecureField("Enter your Bailian API key", text: $key)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("bailianAPIKey")
            Picker("Region", selection: $region) {
                Text("Beijing").tag("cn-beijing")
                Text("Singapore").tag("ap-southeast-1")
            }
            TextField("Workspace ID", text: $workspace).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("bailianWorkspace")
            HStack {
                Text("Stored on this Mac, like DeepSeek. Kept after restart; no Keychain prompt.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Save Bailian") {
                    do {
                        try settings.save(region: region, workspace: workspace, apiKey: key)
                        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        failed = false
                        message = key.isEmpty ? "Key removed. Voice typing will use local recognition."
                            : "Saved. Used by voice typing and Pico meeting features, including after restart."
                    } catch {
                        failed = true; message = "Could not save. Check the key, workspace and local configuration."
                    }
                }.buttonStyle(.bordered).disabled(!loaded)
            }
            if let message { Text(message).font(.system(size: 12)).foregroundStyle(failed ? Color.red : Color.secondary).fixedSize(horizontal: false, vertical: true) }
        }.task {
            guard !loaded else { return }
            do {
                if let saved = try settings.load() {
                    region = saved.region; workspace = saved.workspace; key = saved.apiKey
                    message = key.isEmpty ? "No key saved. Voice typing uses local recognition." : "Saved on this Mac."
                } else {
                    let account = DictationBailianAccount.saved
                    region = account.region.isEmpty ? "cn-beijing" : account.region; workspace = account.workspace
                    // Reuse an already accessible legacy key once, without showing authentication UI.
                    let storage = settings
                    let existing = await Task.detached { BailianCredentialStore.read(account: account.account, settings: storage) }.value
                    if let existing, !existing.isEmpty {
                        try settings.save(region: region, workspace: workspace, apiKey: existing)
                        key = existing; message = "Existing key saved to Pico. No need to enter it again."
                    } else { message = "Enter your key once and save. Future launches will reuse it." }
                }
                loaded = true
            } catch { failed = true; message = "Could not read saved Bailian settings. Existing data has been preserved." }
        }
    }
}

@MainActor final class BailianCredentialWindow: NSObject {
    static let shared = BailianCredentialWindow()
    private var window: NSWindow?
    func show() {
        if window == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Pico · Bailian Settings"; panel.isReleasedWhenClosed = false
            panel.center(); window = panel
        }
        window?.contentView = NSHostingView(rootView: BailianSettingsView().padding(24))
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
