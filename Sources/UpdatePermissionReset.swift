import Foundation

enum UpdatePermissionReset {
    enum Result: Equatable { case unchanged, reset, failed }
    static let marker = "TelosPermissionsResetBuild"

    static func perform(build: String, defaults: UserDefaults = .standard, reset: () -> Bool = resetTelosPermissions) -> Result {
        guard defaults.string(forKey: marker) != build else { return .unchanged }
        guard reset() else { return .failed }
        defaults.set(build, forKey: marker)
        return .reset
    }

    private static func resetTelosPermissions() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        // Never reset another app or the system-wide permission database.
        process.arguments = ["reset", "All", "com.telos.mac"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(8)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate(); return false }
            return process.terminationStatus == 0
        } catch { return false }
    }
}
