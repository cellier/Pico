import Foundation

@main struct ZoomConnectionSettingsTests {
    static func main() async throws {
        let decoder = JSONDecoder()
        let response = Data(#"{"enabled":true,"state":"connected","message":"Verified.","services":[{"id":"meeting","name":"Meetings","available":true,"verified":true}]}"#.utf8)
        let status = try decoder.decode(ZoomConnectionStatus.self, from: response)
        precondition(status.connected && !status.needsSignIn && status.services.first?.id == "meeting" && status.services.first?.verified == true && status.account == nil)
        let signedOut = try decoder.decode(ZoomConnectionStatus.self, from: Data(#"{"enabled":false,"state":"needs_login","message":"Sign in.","services":[]}"#.utf8))
        precondition(!signedOut.connected && signedOut.needsSignIn)
        let catalogOnly = try decoder.decode(ZoomConnectionStatus.self, from: Data(#"{"enabled":true,"state":"connected","message":"Verified contacts.","services":[{"id":"docs","name":"Docs","available":true}]}"#.utf8))
        precondition(catalogOnly.services.first?.available == true && catalogOnly.services.first?.verified != true)
        let stale = ZoomConnectionStatus(enabled: true, state: "stale", message: "Check connection.", services: [], account: nil)
        precondition(!stale.connected)
        let home = URL(fileURLWithPath: "/tmp/pico zoom helper test")
        precondition(ZoomConnectionCommand.helperExecutable(home: home, environment: ["PATH": "/custom/bin"], isExecutable: { $0 == "/custom/bin/helper" }) == "/custom/bin/helper")
        precondition(ZoomConnectionCommand.helperExecutable(home: home, environment: [:], isExecutable: { _ in false }) == nil)
        precondition(ZoomConnectionCommand.helperExecutable(home: home, environment: ["PATH": "/custom/bin"], isExecutable: { $0 == home.appendingPathComponent(".local/bin/helper").path || $0 == "/custom/bin/helper" }) == home.appendingPathComponent(".local/bin/helper").path)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pico zoom settings \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Values resembling shell syntax remain literal arguments and the data path
        // reaches the child process without shell interpolation.
        let source = "import json,os,sys; print(json.dumps([sys.argv[1],os.environ['TELOS_DATA_DIR']]))"
        let literal = "$(no-command); `no-command`"
        let output = try await ZoomConnectionCommand.run(executable: "/usr/bin/python3", arguments: ["-c", source, literal], directory: dir, timeout: 5)
        let arguments = try JSONDecoder().decode([String].self, from: output)
        precondition(arguments == [literal, dir.path])
        let discarded = try await ZoomConnectionCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "print('sensitive-fixture-output')"], directory: dir, timeout: 5, discardOutput: true)
        precondition(discarded.isEmpty)
        do {
            _ = try await ZoomConnectionCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "raise SystemExit(1)"], directory: dir, timeout: 5, discardOutput: true)
            preconditionFailure("Failed sign-in must not be reported as success")
        } catch ZoomConnectionCommand.Failure.failed {}
        let start = Date()
        do {
            _ = try await ZoomConnectionCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "import time; time.sleep(10)"], directory: dir, timeout: 0.15)
            preconditionFailure("Unresponsive connection must time out")
        } catch ZoomConnectionCommand.Failure.timedOut {}
        precondition(Date().timeIntervalSince(start) < 3)
        do {
            _ = try await ZoomConnectionCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys; sys.stdout.write('x' * (3 * 1024 * 1024))"], directory: dir, timeout: 5)
            preconditionFailure("Unexpected unbounded output must not be accepted")
        } catch ZoomConnectionCommand.Failure.invalidResponse {}
        print("PASS: Zoom settings states, helper discovery, literal arguments, credential-output discard, failed login, deadline, output bound")
    }
}
