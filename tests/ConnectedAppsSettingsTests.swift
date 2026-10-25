import Foundation

@main struct ConnectedAppsSettingsTests {
    static func main() async throws {
        let decoder = JSONDecoder()
        let bytes = Data(#"{"apps":[{"id":"figma","name":"Figma","state":"connected","connected":true,"accounts":[{"label":"Design account","active":true},{"label":"Inactive account","active":false},{"label":"Retired account","retired":true}]},{"id":"gmail","state":"unavailable","connected":false,"detail":"Mail service not enabled"}],"identity_state":"ready"}"#.utf8)
        let response = try decoder.decode(ConnectedAppsResponse.self, from: bytes)
        precondition(response.apps[0].verified && response.apps[0].displayState == "Connected")
        precondition(response.apps[0].accountSummary == "Design account")
        precondition(!response.apps[1].verified && response.apps[1].displayState == "Unavailable")
        let catalogOnly = ConnectedAppStatus(id: "notion", name: nil, state: "available", connected: true,
                                            connectURL: nil, detail: nil, accounts: nil)
        precondition(!catalogOnly.verified && catalogOnly.displayState == "Unavailable")
        let mismatch = ConnectedAppStatus(id: "notion", name: nil, state: "connected", connected: false,
                                         connectURL: nil, detail: nil, accounts: nil)
        precondition(!mismatch.verified && mismatch.displayState == "Unavailable")
        precondition(ConnectedAppStatus.disconnected("gmail").displayState == "Not connected")
        precondition(ConnectedAppStatus.connecting("gmail", detail: "Finish sign-in").displayState == "Connecting…")
        let needsSignIn = try decoder.decode(ConnectedAppStatus.self, from: Data(#"{"id":"gmail","state":"needs_authorization","connected":false,"provider":"devhelper"}"#.utf8))
        precondition(needsSignIn.displayState == "Sign-in needed" && needsSignIn.provider == "devhelper")
        precondition(ConnectedAppsCommand.devHelperSignInArguments(for: needsSignIn) == ["auth", "google-mail", "--json"])
        let figmaSignIn = ConnectedAppStatus(id: "figma", name: nil, state: "needs_authorization", connected: false,
                                            connectURL: nil, detail: nil, accounts: nil, provider: "devhelper")
        precondition(ConnectedAppsCommand.devHelperSignInArguments(for: figmaSignIn) == ["auth", "figma", "--json"])
        precondition(ConnectedAppsCommand.devHelperSignInArguments(for: .disconnected("gmail")) == nil)
        let hostedFigma = ConnectedAppStatus(id: "figma", name: nil, state: "disconnected", connected: false,
                                            connectURL: nil, detail: nil, accounts: nil, provider: "hermes")
        precondition(ConnectedAppsCommand.devHelperSignInArguments(for: hostedFigma) == nil)
        let connectedFigma = ConnectedAppStatus(id: "figma", name: nil, state: "connected", connected: true,
                                               connectURL: nil, detail: "Generic permissions", accounts: nil, provider: "devhelper")
        precondition(ConnectedAppsCommand.devHelperSignInArguments(for: connectedFigma) == nil)
        precondition(connectedFigma.displayDetail?.contains("adds comments") == true)
        precondition(connectedFigma.displayDetail?.contains("Editing or deleting design layers") == true)
        let xSetup = ConnectedAppStatus(id: "twitter", name: nil, state: "not_installed", connected: false,
                                       connectURL: nil, detail: nil, accounts: nil, provider: "xurl")
        precondition(xSetup.displayState == "Setup needed" && xSetup.needsXSetup)
        precondition(xSetup.displayDetail?.contains("Terminal") == true)
        precondition(ConnectedAppsCommand.devHelperSignInArguments(for: xSetup) == nil)
        precondition(ConnectedAppsCommand.xSetupURL.absoluteString == "https://github.com/xdevplatform/xurl#authentication")
        let home = URL(fileURLWithPath: "/tmp/pico-connected-app-helper-fixture")
        precondition(ConnectedAppsCommand.helperExecutable(home: home, environment: ["PATH": "/fixture/bin"],
                        isExecutable: { $0 == "/fixture/bin/helper" }) == "/fixture/bin/helper")
        let request = try ConnectedAppsCommand.requestData(action: "connect", connectors: ["gmail"])
        let object = try JSONSerialization.jsonObject(with: request) as! [String: Any]
        precondition(object["action"] as? String == "connect" && object["connectors"] as? [String] == ["gmail"])
        precondition(request.last == 0x0a)
        for invalid in [("delete", ["gmail"]), ("status", ["unknown"]), ("connect", ["gmail", "figma"]), ("status", []), ("status", ["gmail", "gmail"])] {
            do {
                _ = try ConnectedAppsCommand.requestData(action: invalid.0, connectors: invalid.1)
                preconditionFailure("Unexpected request was accepted")
            } catch ConnectedAppsCommand.Failure.invalidRequest {}
        }
        precondition(ConnectedAppsCommand.authorizationURL("https://accounts.example.com/authorize?state=fixture") != nil)
        for invalid in ["file:///tmp/no", "javascript:alert(1)", "http://example.com/auth", "https://user:password@example.com/auth", "https://localhost/auth", "https://127.0.0.1/auth", "https://example.com/auth\n", " https://example.com/auth", "https://example.com/auth\u{0001}"] {
            precondition(ConnectedAppsCommand.authorizationURL(invalid) == nil)
        }
        let redacted = ConnectedAppsCommand.displayText("Open https://accounts.example.com/auth?secret=fixture token=fixture-key")
        precondition(!redacted.contains("fixture") && !redacted.contains("https://"))
        precondition(ConnectedAppsCommand.displayText(String(repeating: "x", count: 1000)).count == 640)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-connected-apps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = "import json,os,sys; value=json.loads(sys.stdin.readline()); print(json.dumps([value['connectors'][0], os.environ['TELOS_DATA_DIR'],sys.argv[1]]))"
        let literal = "$(no-command); `no-command`"
        let output = try await ConnectedAppsCommand.run(executable: "/usr/bin/python3", arguments: ["-c", fixture, literal],
                                                        input: request, directory: directory, timeout: 5)
        let literalResult = try decoder.decode([String].self, from: output)
        precondition(literalResult == ["gmail", directory.path, literal])
        let discarded = try await ConnectedAppsCommand.run(executable: "/usr/bin/python3",
            arguments: ["-c", "print('sensitive-auth-fixture-output')"], input: Data(), directory: directory, timeout: 5, discardOutput: true)
        precondition(discarded.isEmpty)
        do {
            _ = try await ConnectedAppsCommand.run(executable: "/usr/bin/python3",
                arguments: ["-c", "print('sensitive-auth-fixture-output'); raise SystemExit(1)"], input: Data(),
                directory: directory, timeout: 5, discardOutput: true)
            preconditionFailure("Failed authorization process was accepted")
        } catch ConnectedAppsCommand.Failure.failed {}
        let started = Date()
        do {
            _ = try await ConnectedAppsCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "import time;time.sleep(10)"],
                                                   input: Data(), directory: directory, timeout: 0.1)
            preconditionFailure("Unresponsive request did not time out")
        } catch ConnectedAppsCommand.Failure.timedOut {}
        precondition(Date().timeIntervalSince(started) < 3)
        let cancellation = Task {
            try await ConnectedAppsCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "import time;time.sleep(10)"],
                                                input: Data(), directory: directory, timeout: 20)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancellation.cancel()
        do {
            _ = try await cancellation.value
            preconditionFailure("Cancelled request was accepted")
        } catch is CancellationError {}
        do {
            _ = try await ConnectedAppsCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "import sys;sys.stdout.write('x'*200000)"],
                                                   input: Data(), directory: directory, timeout: 5)
            preconditionFailure("Unbounded response was accepted")
        } catch ConnectedAppsCommand.Failure.invalidResponse {}
        do {
            _ = try await ConnectedAppsCommand.run(executable: "/usr/bin/python3", arguments: ["-c", "raise SystemExit(1)"],
                                                   input: Data(), directory: directory, timeout: 5)
            preconditionFailure("Failed request was accepted")
        } catch ConnectedAppsCommand.Failure.failed {}
        print("PASS: Connected apps status/account parsing, catalogue rejection, request/URL validation, safe text, literal stdin/arguments, timeout/cancellation, output bounds and failed process")
    }
}
