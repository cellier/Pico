import AppKit
import Foundation

/// Lifecycle tests inject all launch/process operations; no helper, window or
/// live preference domain is opened by this executable.
@main struct PicoDesktopCompanionTests {
    @MainActor private final class FakeProcess {
        let pid: Int32
        let bundleURL: URL
        var dead = false
        var terminateCalls = 0
        var acceptsTermination = true
        var finishesTerminationImmediately = true
        var onTerminate: (() -> Void)?
        init(_ pid: Int32, _ bundleURL: URL) { self.pid = pid; self.bundleURL = bundleURL }
        var instance: PicoDesktopCompanion.Instance {
            .init(pid: pid, bundleURL: bundleURL, isTerminated: { [unowned self] in self.dead },
                  terminate: { [unowned self] in
                      self.terminateCalls += 1
                      self.onTerminate?()
                      if self.acceptsTermination && self.finishesTerminationImmediately { self.dead = true }
                      return self.acceptsTermination
                  })
        }
    }

    @MainActor private final class FakeDriver {
        enum LaunchMode { case immediate, delayed, failure }
        let helperURL: URL
        var helperAvailable = true
        var mode = LaunchMode.immediate
        var legacy: [FakeProcess] = []
        var launchCalls = 0
        var launched: [FakeProcess] = []
        var environments: [[String: String]] = []
        var events: [String] = []
        private var replies: [(FakeProcess, CheckedContinuation<PicoDesktopCompanion.Instance, Error>)] = []
        init(_ helperURL: URL) { self.helperURL = helperURL }
        var driver: PicoDesktopCompanion.Driver {
            .init(helperURL: { [unowned self] in self.helperAvailable ? self.helperURL : nil },
                  running: { [unowned self] in self.legacy.map(\.instance) },
                  launch: { [unowned self] url, environment in
                      self.launchCalls += 1; self.environments.append(environment)
                      self.events.append("launch")
                      guard self.mode != .failure else { throw CocoaError(.executableNotLoadable) }
                      let process = FakeProcess(Int32(1000 + self.launchCalls), url)
                      self.launched.append(process)
                      if self.mode == .delayed {
                          return try await withCheckedThrowingContinuation { self.replies.append((process, $0)) }
                      }
                      return process.instance
                  })
        }
        func completeOldestLaunch() {
            precondition(!replies.isEmpty, "A delayed launch must be waiting")
            let (process, reply) = replies.removeFirst()
            reply.resume(returning: process.instance)
        }
    }

    private enum Failure: Error { case timeout(String) }
    @MainActor private static var checks = 0
    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }
    @MainActor private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure.timeout(message)
    }
    @MainActor private static func settle() async throws {
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(nanoseconds: 2_000_000)
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PicoDesktopCompanionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var suites: [String] = []
        func preferences() -> UserDefaults {
            let name = "PicoDesktopCompanionTests-" + UUID().uuidString
            suites.append(name)
            return UserDefaults(suiteName: name)!
        }
        defer { for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) } }
        let main = root.appendingPathComponent("Pico.app")
        let helper = main.appendingPathComponent("Contents/Helpers/Pico Desktop.app")
        let data = root.appendingPathComponent("data")
        func controller(_ fake: FakeDriver, _ defaults: UserDefaults, environment: [String: String] = [:]) -> PicoDesktopCompanion {
            .init(directory: data, defaults: defaults, mainBundle: main, ownerPID: 4242,
                  environment: environment, driver: fake.driver)
        }

        // A new installation starts one owned helper; re-entrant starts coalesce.
        do {
            let defaults = preferences(), fake = FakeDriver(helper)
            let companion = controller(fake, defaults)
            expect(companion.enabled, "Missing preference defaults to enabled")
            expect(fake.launchCalls == 0, "Construction alone cannot launch a helper")
            companion.start(); companion.start(); companion.start()
            try await eventually("default launch") { companion.isRunning }
            expect(fake.launchCalls == 1, "Repeated start calls must not duplicate a helper")
            companion.start(); try await settle()
            expect(fake.launchCalls == 1, "A live instance must be reused")
            expect(fake.environments[0] == ["PICO_MANAGED_BY_MAIN": "1", "PICO_MAIN_PID": "4242",
                                           "PICO_APP_PATH": main.standardizedFileURL.path,
                                           "PICO_COMPANION_ROOT": data.appendingPathComponent("companion-v1").path],
                   "The bundled helper receives the exact owner and private IPC directory")
            companion.stop()
            expect(fake.launched[0].dead && !companion.isRunning, "Stopping Pico stops its owned helper")
            expect(companion.enabled && defaults.object(forKey: PicoDesktopCompanion.enabledKey) == nil,
                   "Application shutdown preserves the default preference")
        }

        // User choice persists separately from application lifecycle.
        do {
            let defaults = preferences(), fake = FakeDriver(helper)
            defaults.set(false, forKey: PicoDesktopCompanion.enabledKey)
            let companion = controller(fake, defaults)
            expect(!companion.enabled, "An explicit disabled preference wins over the default")
            companion.start(); try await settle()
            expect(fake.launchCalls == 0, "Disabled startup must not launch")
            companion.enabled = true
            try await eventually("enabled launch") { companion.isRunning }
            expect(defaults.bool(forKey: PicoDesktopCompanion.enabledKey), "Enabling saves the preference")
            companion.enabled = false
            expect(fake.launched[0].dead && !companion.isRunning, "Disabling stops the visible helper immediately")
            let reopened = controller(FakeDriver(helper), UserDefaults(suiteName: suites.last!)!)
            expect(!reopened.enabled, "A fresh settings instance retains the disabled choice")
            companion.stop(); reopened.stop()
            expect(!defaults.bool(forKey: PicoDesktopCompanion.enabledKey), "Shutdown cannot re-enable a disabled preference")
        }

        // Launch Services completion can arrive after off/on. The old result
        // must die before the latest desired instance is allowed to stay alive.
        do {
            let defaults = preferences(), fake = FakeDriver(helper); fake.mode = .delayed
            let companion = controller(fake, defaults)
            companion.start()
            try await eventually("first delayed launch") { fake.launchCalls == 1 }
            companion.enabled = false; companion.enabled = true
            companion.start(); companion.start()
            expect(fake.launchCalls == 1, "An outstanding launch must serialize rapid toggles")
            fake.completeOldestLaunch()
            try await eventually("replacement delayed launch") { fake.launchCalls == 2 }
            expect(fake.launched[0].dead && fake.launched[0].terminateCalls == 1,
                   "A cancelled late launch must not become an orphan")
            fake.completeOldestLaunch()
            try await eventually("replacement accepted") { companion.isRunning }
            expect(!fake.launched[1].dead && fake.launchCalls == 2, "Only the latest desired helper remains alive")
            companion.stop()
            expect(fake.launched[1].dead, "The accepted replacement is owned by the main application")
        }
        do {
            let defaults = preferences(), fake = FakeDriver(helper); fake.mode = .delayed
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("off delayed launch") { fake.launchCalls == 1 }
            companion.enabled = false; fake.completeOldestLaunch()
            try await eventually("late result terminated while off") { fake.launched[0].dead }
            try await settle()
            expect(!companion.isRunning && !companion.enabled && fake.launchCalls == 1,
                   "A late completion while disabled cannot reopen the character")
            companion.stop()
        }
        do {
            let defaults = preferences(), fake = FakeDriver(helper); fake.mode = .delayed
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("stop delayed launch") { fake.launchCalls == 1 }
            companion.stop(); fake.completeOldestLaunch()
            try await eventually("late result terminated after app stop") { fake.launched[0].dead }
            try await settle()
            expect(companion.enabled && !companion.isRunning && fake.launchCalls == 1,
                   "Stopping during launch cannot leak a helper or erase the launch preference")
        }

        do {
            let defaults = preferences(), fake = FakeDriver(helper); fake.mode = .delayed
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("late refusal launch") { fake.launchCalls == 1 }
            let process = fake.launched[0]; process.acceptsTermination = false
            companion.enabled = false; fake.completeOldestLaunch()
            try await eventually("late refusal handled") { process.terminateCalls == 1 }
            try await settle()
            expect(!companion.enabled && companion.isRunning && companion.error != nil && !process.dead,
                   "A late cancelled result refusing termination must be retained and reported as actually running")
            expect(fake.launchCalls == 1, "A disabled late failure must not launch a second helper")
            process.acceptsTermination = true; companion.stop()
            expect(process.dead && !companion.isRunning, "The retained late instance remains available for a later graceful stop")
        }
        do {
            let defaults = preferences(), fake = FakeDriver(helper); fake.mode = .delayed
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("late re-enabled refusal launch") { fake.launchCalls == 1 }
            let process = fake.launched[0]; process.acceptsTermination = false
            companion.enabled = false; companion.enabled = true; fake.completeOldestLaunch()
            try await eventually("late re-enabled result handled") { process.terminateCalls == 1 }
            try await settle()
            expect(companion.enabled && companion.isRunning && companion.error == nil && !process.dead,
                   "Re-enabling may reuse the same owned managed instance if its cancelled quit was refused")
            expect(fake.launchCalls == 1, "Reusing the late owned instance must not duplicate the character")
            process.acceptsTermination = true; companion.stop()
            expect(process.dead && !companion.isRunning, "The reused owned instance is stopped with the main application")
        }

        for key in ["TELOS_PREVIEW", "TELOS_SNAPSHOT"] {
            let defaults = preferences(), fake = FakeDriver(helper)
            let companion = controller(fake, defaults, environment: [key: "fixture"])
            companion.start(); companion.enabled = false; companion.enabled = true; companion.start()
            companion.receiveHideRequest(ownerPID: 4242, mainPath: main.path)
            try await settle()
            expect(fake.launchCalls == 0 && !companion.isRunning, "Preview and snapshot processes cannot launch real desktop helpers")
            expect(companion.enabled, "An unstarted preview ignores external hide requests")
            companion.stop()
        }

        // Missing payload and launcher failure stay visible as errors, and a
        // user retry succeeds without leaving stale error text.
        do {
            let defaults = preferences(), fake = FakeDriver(helper); fake.helperAvailable = false
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("missing helper error") { companion.error != nil }
            expect(companion.enabled && !companion.isRunning && fake.launchCalls == 0,
                   "Enabled preference is not proof that a missing character is running")
            companion.enabled = false
            expect(companion.error == nil, "Disabling clears the failed launch message")
            fake.helperAvailable = true; companion.enabled = true
            try await eventually("retry missing helper") { companion.isRunning }
            expect(companion.error == nil, "A successful retry clears the previous error")
            companion.stop()
        }
        do {
            let defaults = preferences(), fake = FakeDriver(helper); fake.mode = .failure
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("launcher error") { companion.error != nil }
            expect(!companion.isRunning && fake.launchCalls == 1, "Failed launch must not claim a live character")
            companion.enabled = false; fake.mode = .immediate; companion.enabled = true
            try await eventually("launcher retry") { companion.isRunning }
            expect(companion.error == nil && fake.launchCalls == 2, "Off/on explicitly retries a failed launcher")
            companion.stop()
        }

        do {
            let defaults = preferences(), fake = FakeDriver(helper)
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("termination refusal launch") { companion.isRunning }
            let process = fake.launched[0]; process.acceptsTermination = false
            companion.enabled = false
            expect(!companion.enabled && companion.isRunning && !process.dead && companion.error != nil,
                   "A helper refusing normal termination must remain truthfully running with a visible error")
            expect(!defaults.bool(forKey: PicoDesktopCompanion.enabledKey), "Termination failure does not erase the user's disabled choice")
            process.acceptsTermination = true; companion.stop()
            expect(process.dead && !companion.isRunning, "A later graceful stop retries the preserved live instance")
        }

        do {
            let defaults = preferences(), fake = FakeDriver(helper)
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("hide test launch") { companion.isRunning }
            for (owner, path) in [(Int32?.none, main.path), (Int32(99), main.path),
                                  (Int32(4242), root.appendingPathComponent("Other.app").path),
                                  (Int32(4242), String?.none)] {
                companion.receiveHideRequest(ownerPID: owner, mainPath: path)
                expect(companion.enabled && companion.isRunning, "A hide request must match both owner PID and main bundle path")
            }
            companion.receiveHideRequest(ownerPID: 4242, mainPath: main.path)
            expect(!companion.enabled && !companion.isRunning && fake.launched[0].dead,
                   "A valid role-menu hide request controls the same saved setting")
            expect(!defaults.bool(forKey: PicoDesktopCompanion.enabledKey), "Role-menu hiding persists in the main app preference domain")
            companion.stop()
        }

        do {
            let defaults = preferences(), fake = FakeDriver(helper)
            let legacy = FakeProcess(99, root.appendingPathComponent("legacy/Sprout.app"))
            legacy.finishesTerminationImmediately = false
            legacy.onTerminate = { fake.events.append("legacy-terminate") }
            fake.legacy = [legacy]
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("legacy graceful quit requested") { legacy.terminateCalls == 1 }
            expect(fake.launchCalls == 0, "A legacy standalone copy must finish its normal quit before launching the managed helper")
            legacy.dead = true
            try await eventually("managed helper after legacy exit") { companion.isRunning }
            expect(fake.events == ["legacy-terminate", "launch"], "Migration must preserve graceful quit-before-launch ordering")
            companion.stop()
        }
        do {
            let defaults = preferences(), fake = FakeDriver(helper)
            let legacy = FakeProcess(98, root.appendingPathComponent("busy/Sprout.app")); legacy.acceptsTermination = false
            fake.legacy = [legacy]
            let companion = controller(fake, defaults)
            companion.start(); try await eventually("legacy refusal surfaced") { companion.error != nil }
            expect(fake.launchCalls == 0 && !companion.isRunning && !legacy.dead,
                   "A legacy copy refusing normal quit must not be force-killed or duplicated")
            companion.stop()
        }

        // Filesystem verification uses inert executable fixtures, never runs them.
        let fm = FileManager.default
        func helperBundle(_ name: String, id: String = PicoDesktopCompanion.helperIdentifier,
                          executable: String = "Sprout", permissions: Int = 0o755) throws -> URL {
            let bundle = root.appendingPathComponent(name)
            try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": id, "CFBundleExecutable": executable]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
            let binary = bundle.appendingPathComponent("Contents/MacOS/Sprout")
            try Data("inert test payload".utf8).write(to: binary)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: binary.path)
            return bundle
        }
        let valid = try helperBundle("valid.app")
        expect(PicoDesktopCompanion.validHelper(valid), "The bundled helper identifier and executable are accepted")
        let wrongID = try helperBundle("wrong-id.app", id: "other.app")
        let wrongBinary = try helperBundle("wrong-binary.app", executable: "Other")
        let noExecute = try helperBundle("no-execute.app", permissions: 0o644)
        expect(!PicoDesktopCompanion.validHelper(wrongID), "Wrong application identifier cannot be launched")
        expect(!PicoDesktopCompanion.validHelper(wrongBinary), "Unexpected executable cannot be launched")
        expect(!PicoDesktopCompanion.validHelper(noExecute), "An inert non-executable payload cannot be launched")
        try fm.removeItem(at: valid.appendingPathComponent("Contents/MacOS/Sprout"))
        expect(!PicoDesktopCompanion.validHelper(valid), "A missing helper executable is rejected")
        try fm.createDirectory(at: valid.appendingPathComponent("Contents/MacOS/Sprout"), withIntermediateDirectories: false)
        expect(!PicoDesktopCompanion.validHelper(valid), "A directory is not a helper executable")
        print("PASS: PicoDesktopCompanion \(checks) lifecycle checks; fake launch/process operations, private defaults only, no UI or real helper")
    }
}
