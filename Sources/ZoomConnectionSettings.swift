import AppKit
import Foundation
import SwiftUI
import Darwin

extension Notification.Name {
    static let picoZoomConnectionChanged = Notification.Name("PicoZoomConnectionChanged")
}

/// Pico stores only its own access switch and a verified capability summary.
/// Zoom/Okta credentials remain in DevHelper's existing credential vault.
struct ZoomConnectionStatus: Decodable, Equatable {
    struct Service: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        let available: Bool
        let verified: Bool?
        let readToolCount: Int?
        let writeToolCount: Int?

        private enum CodingKeys: String, CodingKey {
            case id, name, available, verified
            case readToolCount = "read_tool_count"
            case writeToolCount = "write_tool_count"
        }
        var actionSummary: String? {
            var parts: [String] = []
            if let readToolCount { parts.append("Read \(readToolCount)") }
            if let writeToolCount { parts.append("Change \(writeToolCount)") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
    let enabled: Bool
    let state: String
    let message: String
    let services: [Service]
    let account: String?

    var connected: Bool { enabled && state == "connected" }
    var needsSignIn: Bool { ["needs_login", "auth_required", "authentication_required", "expired"].contains(state) }
    static let initial = Self(enabled: false, state: "loading", message: "Checking Zoom connection…", services: [], account: nil)
}

enum ZoomConnectionCommand {
    enum Failure: LocalizedError {
        case missingRuntime, missingHelper, failed, timedOut, invalidResponse
        var errorDescription: String? {
            switch self {
            case .missingRuntime: return "Zoom connection tools are unavailable in this build."
            case .missingHelper: return "Install DevHelper on this Mac, then connect Zoom again."
            case .failed: return "Zoom sign-in did not finish. Please try again."
            case .timedOut: return "Zoom did not respond in time. Please try again."
            case .invalidResponse: return "Could not read the Zoom connection status."
            }
        }
    }
    static func helperExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                 environment: [String: String] = ProcessInfo.processInfo.environment,
                                 isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> String? {
        let known = [home.appendingPathComponent(".local/bin/helper").path,
                     "/opt/homebrew/bin/helper", "/usr/local/bin/helper"]
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/helper" }
        return (known + paths).first(where: isExecutable)
    }
    /// Uses argument arrays, never a shell; output is not logged or presented to the user.
    static func run(executable: String, arguments: [String], directory: URL, timeout: TimeInterval,
                    discardOutput: Bool = false) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process(), output = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                env["TELOS_DATA_DIR"] = directory.path
                process.environment = env
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                let timeoutFlag = ZoomCommandTimeout()
                let timer = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timeoutFlag.mark()
                    process.terminate()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                do {
                    try process.run()
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
                    var bytes = Data()
                    var oversized = false
                    while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                        if !discardOutput {
                            if bytes.count + chunk.count > 2 * 1024 * 1024 {
                                oversized = true
                                process.terminate()
                            } else if !oversized { bytes.append(chunk) }
                        }
                    }
                    process.waitUntilExit()
                    timer.cancel()
                    if timeoutFlag.expired { throw Failure.timedOut }
                    if oversized { throw Failure.invalidResponse }
                    // Connector errors also return structured status JSON. Login success
                    // is the only operation whose exit status is used directly here.
                    if discardOutput && process.terminationStatus != 0 { throw Failure.failed }
                    continuation.resume(returning: bytes)
                } catch {
                    timer.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private final class ZoomCommandTimeout: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func mark() { lock.lock(); value = true; lock.unlock() }
}

@MainActor final class ZoomConnectionModel: ObservableObject {
    @Published private(set) var status = ZoomConnectionStatus.initial
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var activity = "Checking…"
    private let directory: URL
    init(directory: URL) { self.directory = directory }

    func perform(_ action: String) async {
        guard !busy else { return }
        busy = true; error = nil
        activity = action == "disconnect" ? "Disconnecting…" : action == "connect" ? "Connecting…" : "Checking…"
        defer { busy = false }
        do { try await update(action) }
        catch { self.error = (error as? ZoomConnectionCommand.Failure)?.localizedDescription ?? "Could not check Zoom. Please try again." }
    }
    func signIn() async {
        guard !busy else { return }
        busy = true; error = nil; activity = "Waiting for sign-in…"
        defer { busy = false }
        do {
            guard let helper = ZoomConnectionCommand.helperExecutable() else { throw ZoomConnectionCommand.Failure.missingHelper }
            // The official CLI opens its own browser authorization flow. No tokens
            // are copied from Codex, other clients, stdout, or the user's files.
            _ = try await ZoomConnectionCommand.run(executable: helper, arguments: ["login", "--json"],
                                                     directory: directory, timeout: 600, discardOutput: true)
            try await update("connect")
        } catch { self.error = (error as? ZoomConnectionCommand.Failure)?.localizedDescription ?? "Zoom sign-in did not finish. Please try again." }
    }
    private func update(_ action: String) async throws {
        guard ["status", "connect", "disconnect"].contains(action) else { throw ZoomConnectionCommand.Failure.invalidResponse }
        guard let python = BundledRuntime.python(),
              let script = Bundle.main.resourceURL?.appendingPathComponent("Backend/zoom_connector.py"),
              FileManager.default.fileExists(atPath: script.path) else { throw ZoomConnectionCommand.Failure.missingRuntime }
        let bytes = try await ZoomConnectionCommand.run(executable: python, arguments: ["-B", script.path, action],
                                                        directory: directory, timeout: action == "connect" ? 120 : 15)
        guard let result = try? JSONDecoder().decode(ZoomConnectionStatus.self, from: bytes) else { throw ZoomConnectionCommand.Failure.invalidResponse }
        status = result
        if action != "status" {
            NotificationCenter.default.post(name: .picoZoomConnectionChanged, object: nil,
                                            userInfo: ["directory": directory.path, "state": result.state, "message": result.message])
        }
    }
}

struct ZoomConnectionSettingsView: View {
    @StateObject private var model: ZoomConnectionModel
    init(directory: URL) { _model = StateObject(wrappedValue: ZoomConnectionModel(directory: directory)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Zoom", systemImage: "video").font(.system(size: 14, weight: .medium))
                Spacer()
                Text("Read & write").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Uses your connected Zoom account to find information, send messages and make changes you request. Your Zoom permissions still apply.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("For actions without an account API, including Slides and Paper editing, Pico can use your signed-in Zoom website or app through Mac Access. It checks the actual saved result.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(model.status.message).font(.system(size: 13)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("zoomConnectionStatus")
            if let account = model.status.account, !account.isEmpty {
                Text(account).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            }
            let available = model.status.services.filter(\.available)
            if !available.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Supported services").fontWeight(.medium)
                    ForEach(available) { service in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(service.name).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if let summary = service.actionSummary {
                                Text(summary).multilineTextAlignment(.trailing)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("zoomServiceActions-" + service.id)
                    }
                }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("zoomConnectedServices")
            }
            let verified = available.filter { $0.verified == true }
            if !verified.isEmpty {
                Text("Read access checked: " + verified.map(\.name).joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("zoomVerifiedServices")
            }
            if !available.isEmpty {
                Text("A successful read does not confirm permission to make changes. Each change reports whether Zoom accepted it and whether the result was checked.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text(model.activity).font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button(model.status.enabled ? "Check connection" : "Connect Zoom") { Task { await model.perform("connect") } }
                        .buttonStyle(.bordered).nativeHoverFeedback().accessibilityIdentifier("connectZoom")
                    if model.status.needsSignIn {
                        Button("Sign in…") { Task { await model.signIn() } }
                            .buttonStyle(.bordered).nativeHoverFeedback().accessibilityIdentifier("signInZoom")
                    }
                    if model.status.enabled {
                        Button("Disconnect") { Task { await model.perform("disconnect") } }
                            .buttonStyle(.bordered).nativeHoverFeedback().accessibilityIdentifier("disconnectZoom")
                    }
                }
            }
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Pico does not copy your Zoom credentials. Disconnecting turns off Zoom access in Pico and keeps DevHelper signed in.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.perform("status") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.perform("status") }
        }
    }
}
