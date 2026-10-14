import Foundation

enum UpdatePermissionReset {
    // Only this explicit user repair remains. Never reset permissions on build changes.
    static func resetAccessibility() -> Bool { resetPermission("Accessibility") }

    private static func resetPermission(_ service: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        // Never reset another app or the system-wide permission database.
        process.arguments = ["reset", service, "com.telos.mac"]
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
