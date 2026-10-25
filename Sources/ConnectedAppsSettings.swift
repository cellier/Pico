import AppKit
import Foundation
import SwiftUI
import Darwin

struct ConnectedAppStatus: Decodable, Equatable, Identifiable {
    struct Account: Decodable, Equatable {
        let alias: String?
        let label: String?
        let status: String?
        let active: Bool?
        let retired: Bool?
    }
    let id: String
    let name: String?
    let state: String
    let connected: Bool
    let connectURL: String?
    let detail: String?
    let accounts: [Account]?
    let provider: String?

    init(id: String, name: String?, state: String, connected: Bool, connectURL: String?,
         detail: String?, accounts: [Account]?, provider: String? = nil) {
        self.id = id; self.name = name; self.state = state; self.connected = connected
        self.connectURL = connectURL; self.detail = detail; self.accounts = accounts; self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, state, connected, detail, accounts, provider
        case connectURL = "connect_url"
    }
    var verified: Bool { state == "connected" && connected }
    var displayState: String {
        if verified { return "Connected" }
        switch state {
        case "connecting": return "Connecting…"
        case "disconnected": return "Not connected"
        case "needs_authorization", "needs_auth": return "Sign-in needed"
        case "not_installed": return "Setup needed"
        default: return "Unavailable"
        }
    }
    var accountSummary: String? {
        guard verified else { return nil }
        let labels = (accounts ?? []).filter { $0.active != false && $0.retired != true }.compactMap { $0.label ?? $0.alias }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return labels.isEmpty ? nil : labels.joined(separator: " · ")
    }
    var displayDetail: String? {
        if id == "figma", provider == "devhelper", verified {
            return "Reads design files and adds comments. Editing or deleting design layers is not available through this connection."
        }
        if needsXSetup {
            return "Complete the official X setup in Terminal with your own developer app, then return here and check the connection."
        }
        return detail
    }
    var needsXSetup: Bool {
        id == "twitter" && !verified && ["needs_authorization", "needs_auth", "not_installed"].contains(state)
    }
    static func disconnected(_ id: String) -> Self {
        Self(id: id, name: nil, state: "disconnected", connected: false, connectURL: nil, detail: nil, accounts: nil)
    }
    static func connecting(_ id: String, detail: String) -> Self {
        Self(id: id, name: nil, state: "connecting", connected: false, connectURL: nil, detail: detail, accounts: nil)
    }
}

struct ConnectedAppsResponse: Decodable {
    struct BackendError: Decodable { let code: String?; let message: String? }
    let apps: [ConnectedAppStatus]
    let identityState: String?
    let error: BackendError?
    private enum CodingKeys: String, CodingKey {
        case apps, error
        case identityState = "identity_state"
    }
}

enum ConnectedAppsCommand {
    enum Failure: LocalizedError {
        case missingRuntime, invalidRequest, invalidResponse, failed, timedOut, invalidAuthorizationURL
        var errorDescription: String? {
            switch self {
            case .missingRuntime: return "Connected apps are unavailable in this build."
            case .invalidRequest, .invalidResponse: return "Could not read the app connection. Please check again."
            case .failed: return "Could not check this connection. Please try again."
            case .timedOut: return "The connection did not respond in time. Please try again."
            case .invalidAuthorizationURL: return "Could not open a secure sign-in page. Please try again."
            }
        }
    }
    static let connectorIDs = ["gmail", "twitter", "notion", "figma"]
    static let xSetupURL = URL(string: "https://github.com/xdevplatform/xurl#authentication")!

    static func helperExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let known = [home.appendingPathComponent(".local/bin/helper").path, "/opt/homebrew/bin/helper", "/usr/local/bin/helper"]
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/helper" }
        return (known + paths).first(where: isExecutable)
    }

    static func devHelperSignInArguments(for app: ConnectedAppStatus) -> [String]? {
        guard app.provider == "devhelper", !app.connected else { return nil }
        switch app.id {
        case "gmail": return ["auth", "google-mail", "--json"]
        case "figma": return ["auth", "figma", "--json"]
        default: return nil
        }
    }

    /// Only the native Connect button calls this; backend/LLM tools cannot
    /// start DevHelper authentication. The person completes browser OAuth.
    static func signIn(_ app: ConnectedAppStatus, directory: URL) async throws {
        guard let arguments = devHelperSignInArguments(for: app) else { throw Failure.invalidRequest }
        guard let helper = helperExecutable() else { throw Failure.missingRuntime }
        _ = try await run(executable: helper, arguments: arguments, input: Data(), directory: directory,
                          timeout: 180, discardOutput: true)
    }

    static func authorizationURL(_ value: String) -> URL? {
        // Only a returned web authorization link is opened. No custom schemes,
        // executable URLs, embedded passwords or local service endpoints.
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil, let host = parts.host?.lowercased(),
              host.contains("."), host != "localhost", !host.hasSuffix(".localhost"),
              host != "127.0.0.1", host != "0.0.0.0", host != "::1",
              let url = parts.url else { return nil }
        return url
    }

    static func displayText(_ value: String) -> String {
        String(value.prefix(640))
            .replacingOccurrences(of: #"https?://\S+"#, with: "[sign-in link]", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(token|api[ _-]?key|authorization|secret|password)\s*[:=]\s*\S+"#,
                                  with: "$1: [hidden]", options: .regularExpression)
    }

    static func requestData(action: String, connectors: [String]) throws -> Data {
        guard ["status", "connect"].contains(action), !connectors.isEmpty,
              Set(connectors).count == connectors.count,
              connectors.allSatisfy(connectorIDs.contains), action != "connect" || connectors.count == 1 else {
            throw Failure.invalidRequest
        }
        var data = try JSONSerialization.data(withJSONObject: ["action": action, "connectors": connectors])
        data.append(0x0a)
        return data
    }

    static func perform(action: String, connectors: [String], directory: URL) async throws -> ConnectedAppsResponse {
        guard let python = BundledRuntime.python(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/connected_apps.py"),
              FileManager.default.fileExists(atPath: script.path) else { throw Failure.missingRuntime }
        let data = try requestData(action: action, connectors: connectors)
        let output = try await run(executable: python, arguments: ["-B", script.path, "--data", directory.path],
                                   input: data, directory: directory, timeout: 75)
        guard let response = try? JSONDecoder().decode(ConnectedAppsResponse.self, from: output),
              Set(response.apps.map(\.id)).count == response.apps.count,
              response.apps.allSatisfy({ connectorIDs.contains($0.id) }) else { throw Failure.invalidResponse }
        return response
    }

    /// Runs off the main actor with bounded output, cancellation and a deadline.
    /// Raw backend errors and authorization URLs never reach logs or UI errors.
    static func run(executable: String, arguments: [String], input: Data, directory: URL,
                    timeout: TimeInterval, discardOutput: Bool = false) async throws -> Data {
        let cancellation = ConnectedAppsCancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let process = Process(), output = Pipe(), stdin = Pipe()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["TELOS_DATA_DIR"] = directory.path
                    process.environment = environment
                    process.standardOutput = output
                    process.standardError = FileHandle.nullDevice
                    process.standardInput = stdin
                    do {
                        guard input.count <= 4096, timeout > 0 else { throw Failure.invalidRequest }
                        if cancellation.cancelled { throw CancellationError() }
                        try process.run()
                        let descriptor = output.fileHandleForReading.fileDescriptor
                        let flags = fcntl(descriptor, F_GETFL)
                        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                            throw Failure.failed
                        }
                        try stdin.fileHandleForWriting.write(contentsOf: input)
                        try stdin.fileHandleForWriting.close()
                        let deadline = ProcessInfo.processInfo.systemUptime + timeout
                        var bytes = Data(), total = 0, buffer = [UInt8](repeating: 0, count: 16384)
                        while true {
                            if cancellation.cancelled { throw CancellationError() }
                            if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure.timedOut }
                            let length = Darwin.read(descriptor, &buffer, buffer.count)
                            if length > 0 {
                                total += length
                                guard total <= 128 * 1024 else { throw Failure.invalidResponse }
                                if !discardOutput { bytes.append(contentsOf: buffer.prefix(length)) }
                                continue
                            }
                            // Do not wait for EOF from a grandchild which inherited
                            // stdout after the request process itself has exited.
                            if !process.isRunning { break }
                            if length < 0 && errno != EAGAIN && errno != EINTR { throw Failure.failed }
                            usleep(20_000)
                        }
                        process.waitUntilExit()
                        try? output.fileHandleForReading.close()
                        guard process.terminationStatus == 0 || (!discardOutput && !bytes.isEmpty) else { throw Failure.failed }
                        continuation.resume(returning: bytes)
                    } catch {
                        if process.isRunning {
                            process.terminate()
                            let stop = ProcessInfo.processInfo.systemUptime + 0.5
                            while process.isRunning && ProcessInfo.processInfo.systemUptime < stop { usleep(10_000) }
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                        }
                        try? stdin.fileHandleForWriting.close()
                        try? output.fileHandleForReading.close()
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }
}

private final class ConnectedAppsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

@MainActor final class ConnectedAppsModel: ObservableObject {
    @Published private(set) var apps: [String: ConnectedAppStatus] =
        Dictionary(uniqueKeysWithValues: ConnectedAppsCommand.connectorIDs.map { ($0, .disconnected($0)) })
    @Published private(set) var busyIDs: Set<String> = []
    @Published private(set) var connecting = false
    @Published private(set) var errors: [String: String] = [:]
    private let directory: URL
    private var request: Task<Void, Never>?
    private var generation = UUID()

    init(directory: URL) { self.directory = directory }

    func refresh(_ ids: [String] = ConnectedAppsCommand.connectorIDs) {
        start(action: "status", ids: ids)
    }
    func connect(_ id: String) { start(action: "connect", ids: [id]) }
    func openXSetup() {
        if !NSWorkspace.shared.open(ConnectedAppsCommand.xSetupURL) {
            errors["twitter"] = "Could not open the X setup instructions. Please try again."
        }
    }
    func cancel() {
        generation = UUID()
        request?.cancel(); request = nil
        busyIDs.removeAll()
        connecting = false
    }
    private func start(action: String, ids: [String]) {
        guard request == nil, !ids.isEmpty else { return }
        busyIDs = Set(ids)
        connecting = action == "connect"
        for id in ids { errors[id] = nil }
        let current = UUID(); generation = current
        request = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == current {
                    self.request = nil; self.busyIDs.removeAll(); self.connecting = false
                }
            }
            do {
                let response = try await ConnectedAppsCommand.perform(action: action, connectors: ids, directory: self.directory)
                try Task.checkCancellation()
                guard self.generation == current else { return }
                if action == "status" {
                    self.applyStatus(response, ids: ids)
                } else if let app = response.apps.first(where: { $0.id == ids.first }),
                          ConnectedAppsCommand.devHelperSignInArguments(for: app) != nil {
                    self.apps[app.id] = .connecting(app.id, detail: "Finish sign-in in your browser. Pico will check the connection when it finishes.")
                    try await ConnectedAppsCommand.signIn(app, directory: self.directory)
                    try Task.checkCancellation()
                    let checked = try await ConnectedAppsCommand.perform(action: "status", connectors: ids, directory: self.directory)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    self.applyStatus(checked, ids: ids)
                } else if let app = response.apps.first(where: { $0.id == ids.first }),
                          let link = app.connectURL {
                    guard let url = ConnectedAppsCommand.authorizationURL(link), NSWorkspace.shared.open(url) else {
                        throw ConnectedAppsCommand.Failure.invalidAuthorizationURL
                    }
                    self.apps[app.id] = .connecting(app.id, detail: "Finish sign-in in your browser, then check the connection.")
                } else {
                    // A connect acknowledgement never establishes connected state.
                    let checked = try await ConnectedAppsCommand.perform(action: "status", connectors: ids, directory: self.directory)
                    try Task.checkCancellation()
                    guard self.generation == current else { return }
                    self.applyStatus(checked, ids: ids)
                }
            } catch is CancellationError {
                // Closing Settings stops its request without showing a false error.
            } catch {
                guard self.generation == current else { return }
                let message = (error as? ConnectedAppsCommand.Failure)?.localizedDescription
                    ?? "Could not check this connection. Please try again."
                for id in ids {
                    self.errors[id] = message
                    self.apps[id] = ConnectedAppStatus(id: id, name: nil, state: "unavailable", connected: false,
                                                       connectURL: nil, detail: nil, accounts: nil)
                }
            }
        }
    }
    private func applyStatus(_ response: ConnectedAppsResponse, ids: [String]) {
        for id in ids {
            if let app = response.apps.first(where: { $0.id == id }) { apps[id] = app }
            else {
                apps[id] = ConnectedAppStatus(id: id, name: nil, state: "unavailable", connected: false,
                                             connectURL: nil, detail: "Connection status is unavailable. Please check again.", accounts: nil)
            }
        }
    }
}

struct ConnectedAppsSettingsView: View {
    @StateObject private var model: ConnectedAppsModel
    private let names = ["gmail": "Gmail", "twitter": "Twitter / X", "notion": "Notion", "figma": "Figma"]
    init(directory: URL) { _model = StateObject(wrappedValue: ConnectedAppsModel(directory: directory)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connected Apps").font(.system(size: 14, weight: .medium))
            Text("Connect your accounts so Pico can find information and make the changes you request. Available actions depend on each app and your account permissions.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ConnectedAppsCommand.connectorIDs, id: \.self) { id in
                appRow(id)
            }
        }
        .accessibilityIdentifier("connectedAppsSettings")
        .onAppear { model.refresh() }
        .onDisappear { model.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }

    private func appRow(_ id: String) -> some View {
        let app = model.apps[id] ?? .disconnected(id)
        let busy = model.busyIDs.contains(id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(names[id] ?? id).font(.system(size: 13, weight: .medium))
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                Text(busy ? (model.connecting ? "Connecting…" : "Checking…") : app.displayState)
                    .font(.system(size: 12)).foregroundStyle(app.verified ? Color.green : Color.secondary)
                    .accessibilityIdentifier("connectedAppStatus-" + id)
            }
            if let summary = app.accountSummary {
                Text(ConnectedAppsCommand.displayText(summary)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = app.displayDetail, !detail.isEmpty {
                Text(ConnectedAppsCommand.displayText(detail)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if app.needsXSetup {
                    Button("Setup X…") { model.openXSetup() }
                        .buttonStyle(.bordered).nativeHoverFeedback()
                        .help("Open the official X setup instructions. Complete authorization yourself in Terminal.")
                        .accessibilityIdentifier("setupApp-twitter")
                } else if !app.verified && app.state != "connecting" {
                    Button("Connect…") { model.connect(id) }
                        .buttonStyle(.bordered).nativeHoverFeedback()
                        .accessibilityIdentifier("connectApp-" + id)
                }
                Button("Check connection") { model.refresh([id]) }
                    .buttonStyle(.bordered).nativeHoverFeedback()
                    .accessibilityIdentifier("checkApp-" + id)
            }.disabled(!model.busyIDs.isEmpty)
            if let error = model.errors[id] {
                Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("connectedApp-" + id)
    }
}
