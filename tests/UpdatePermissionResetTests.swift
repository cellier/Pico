import Foundation
@main struct UpdatePermissionResetTests {
    static func main() {
        let name = "TelosPermissionResetTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var calls = 0
        func reset() -> Bool { calls += 1; return true }
        precondition(UpdatePermissionReset.perform(build: "a", defaults: defaults, reset: reset) == .reset)
        precondition(UpdatePermissionReset.perform(build: "a", defaults: defaults, reset: reset) == .unchanged)
        precondition(calls == 1)
        precondition(UpdatePermissionReset.perform(build: "b", defaults: defaults, reset: { false }) == .failed)
        precondition(defaults.string(forKey: UpdatePermissionReset.marker) == "a")
        precondition(UpdatePermissionReset.perform(build: "b", defaults: defaults, reset: reset) == .reset)
        precondition(calls == 2)
        print("PASS: reset once per build, same-build relaunch unchanged, failed reset not recorded; no real permissions changed")
    }
}
