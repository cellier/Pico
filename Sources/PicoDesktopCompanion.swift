import AppKit
import Combine
import SwiftUI

/// The desktop character is bundled with Pico and shares its application lifetime.
@MainActor final class PicoDesktopCompanion: ObservableObject {
    static let enabledKey = "PicoDesktopCompanionEnabled"
    static let hideNotification = Notification.Name("com.telos.mac.desktopCompanion.hide")
    nonisolated static let helperIdentifier = "local.original.sprout"

    struct Instance {
        let pid: Int32
        let bundleURL: URL
        var isTerminated: () -> Bool
        var terminate: () -> Bool
    }
    struct Driver {
        var helperURL: () -> URL?
        var running: () -> [Instance]
        var launch: (URL, [String: String]) async throws -> Instance

        static func live(mainBundle: URL) -> Driver {
            func instance(_ app: NSRunningApplication) -> Instance? {
                guard app.bundleIdentifier == PicoDesktopCompanion.helperIdentifier,
                      let url = app.bundleURL, PicoDesktopCompanion.validHelper(url) else { return nil }
                return Instance(pid: app.processIdentifier, bundleURL: url,
                                isTerminated: { app.isTerminated }, terminate: { app.terminate() })
            }
            return Driver(helperURL: {
                let url = mainBundle.appendingPathComponent("Contents/Helpers/Pico Desktop.app")
                return PicoDesktopCompanion.validHelper(url) ? url : nil
            }, running: {
                NSWorkspace.shared.runningApplications.compactMap(instance)
            }, launch: { url, environment in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.promptsUserIfNeeded = false
                configuration.environment = environment
                return try await withCheckedThrowingContinuation { continuation in
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                        DispatchQueue.main.async {
                            if let error { continuation.resume(throwing: error) }
                            else if let app, let value = instance(app) { continuation.resume(returning: value) }
                            else { continuation.resume(throwing: CocoaError(.executableNotLoadable)) }
                        }
                    }
                }
            })
        }
    }

    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            reconcile()
        }
    }
    @Published private(set) var error: String?
    @Published private(set) var isRunning = false
    private let defaults: UserDefaults
    private let directory: URL
    private let mainBundle: URL
    private let ownerPID: Int32
    private let environment: [String: String]
    private let driver: Driver
    private var started = false
    private var instance: Instance?
    private var launchTask: Task<Void, Never>?
    private var reconcilePending = false
    private var hideObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    init(directory: URL, defaults: UserDefaults = .standard,
         mainBundle: URL = Bundle.main.bundleURL,
         ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         driver: Driver? = nil) {
        self.directory = directory; self.defaults = defaults
        self.mainBundle = mainBundle.standardizedFileURL; self.ownerPID = ownerPID
        self.environment = environment; self.driver = driver ?? .live(mainBundle: mainBundle)
        enabled = defaults.object(forKey: Self.enabledKey) == nil || defaults.bool(forKey: Self.enabledKey)
    }

    nonisolated static func validHelper(_ bundle: URL) -> Bool {
        guard let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == helperIdentifier,
              info["CFBundleExecutable"] as? String == "Sprout" else { return false }
        let binary = bundle.appendingPathComponent("Contents/MacOS/Sprout")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: binary.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: binary.path)
    }

    func start() {
        guard environment["TELOS_PREVIEW"] == nil, environment["TELOS_SNAPSHOT"] == nil else { return }
        if !started {
            started = true
            hideObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.hideNotification, object: mainBundle.path, queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.receiveHideRequest(ownerPID: (notification.userInfo?["owner_pid"] as? NSNumber)?.int32Value,
                                             mainPath: notification.object as? String)
                }
            }
            terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.instance?.pid == app.processIdentifier else { return }
                    self.instance = nil; self.isRunning = false
                    if self.started, self.enabled {
                        self.error = "Desktop Pico stopped. Turn this setting off and on to show it again."
                    }
                }
            }
        }
        reconcile()
    }

    func receiveHideRequest(ownerPID: Int32?, mainPath: String?) {
        guard started, ownerPID == self.ownerPID, mainPath == mainBundle.path else { return }
        enabled = false
    }

    /// Quitting Pico preserves the preference for the next launch.
    func stop() {
        started = false; reconcilePending = false
        if let hideObserver { DistributedNotificationCenter.default().removeObserver(hideObserver) }
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        hideObserver = nil
        terminationObserver = nil
        launchTask?.cancel()
        stopInstance()
    }

    private func stopInstance() {
        if let instance, !instance.isTerminated(), !instance.terminate() {
            isRunning = true
            error = "Could not hide desktop Pico. Turn this setting on and off to try again."
            return
        }
        instance = nil; isRunning = false
    }

    private func reconcile() {
        guard started, enabled else {
            error = nil
            launchTask?.cancel()
            stopInstance()
            return
        }
        if let instance, !instance.isTerminated() { error = nil; return }
        instance = nil; isRunning = false
        if launchTask != nil { reconcilePending = true; return }
        error = nil
        launchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.launchTask = nil
                if self.reconcilePending {
                    self.reconcilePending = false
                    self.reconcile()
                }
            }
            do {
                guard let helper = self.driver.helperURL() else {
                    throw NSError(domain: "Pico.DesktopCompanion", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The desktop character is missing from this Pico installation."])
                }
                // Launch Services may otherwise reuse a legacy standalone copy
                // with no owner, leaving two independent application lifetimes.
                for old in self.driver.running() where !old.isTerminated() {
                    guard old.terminate() else { throw CocoaError(.userCancelled) }
                    for _ in 0..<60 where !old.isTerminated() {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    guard old.isTerminated() else { throw CocoaError(.executableLoad) }
                }
                try Task.checkCancellation()
                let launched = try await self.driver.launch(helper, [
                    "PICO_MANAGED_BY_MAIN": "1", "PICO_MAIN_PID": String(self.ownerPID),
                    "PICO_APP_PATH": self.mainBundle.path,
                    "PICO_COMPANION_ROOT": self.directory.appendingPathComponent("companion-v1").path
                ])
                guard !Task.isCancelled, self.started, self.enabled else {
                    self.instance = launched
                    self.stopInstance()
                    return
                }
                self.instance = launched; self.isRunning = !launched.isTerminated()
                if !self.isRunning { throw CocoaError(.executableNotLoadable) }
            } catch {
                if !Task.isCancelled, self.started, self.enabled {
                    self.error = "Could not show desktop Pico. Turn this setting off and on to try again."
                }
            }
        }
    }
}

struct PicoDesktopCompanionSettings: View {
    @ObservedObject var companion: PicoDesktopCompanion
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show Pico on desktop", isOn: $companion.enabled)
                .font(.system(size: 14, weight: .medium))
                .accessibilityIdentifier("picoDesktopCompanionEnabled")
            Text("Shows the floating character while Pico is open. Changes apply immediately.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if let error = companion.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("picoDesktopCompanionError")
            }
        }
    }
}
