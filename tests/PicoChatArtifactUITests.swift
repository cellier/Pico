import AppKit
import SwiftUI
import Vision

/// Render real Chat rows against private persisted history. No agent or file-open
/// action runs; physical window pixels establish which reply owns each file.
@main struct PicoChatArtifactUITests {
    @MainActor static func main() throws {
        let originalEnvironment = ProcessInfo.processInfo.environment
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("pico-artifact-ui-" + UUID().uuidString)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/pico-chat-artifact-ui-tests")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        unsetenv("TELOS_PREVIEW")
        setenv("TELOS_DATA_DIR", data.path, 1)
        defer {
            try? FileManager.default.removeItem(at: data)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW"] {
                if let value = originalEnvironment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let firstFile = Artifact(path: data.appendingPathComponent("alpha-note.md").path, name: "alpha-note.md")
        let secondFile = Artifact(path: data.appendingPathComponent("beta-report.md").path, name: "beta-report.md")
        try Data("First output".utf8).write(to: URL(fileURLWithPath: firstFile.path))
        try Data("Second output".utf8).write(to: URL(fileURLWithPath: secondFile.path))
        let firstOwner = Message(role: "assistant", text: "FIRST OUTPUT READY", artifacts: [firstFile])
        let secondOwner = Message(role: "assistant", text: "SECOND OUTPUT READY", artifacts: [secondFile])
        let messages = [Message(role: "user", text: "Create the first file."), firstOwner,
                        Message(role: "user", text: "FOLLOWUP AFTER FIRST OUTPUT"), secondOwner,
                        Message(role: "user", text: "FOLLOWUP AFTER SECOND OUTPUT"),
                        Message(role: "assistant", text: "LATEST FOLLOWUP HAS NO FILES")]
        struct Snapshot: Encodable {
            var conversationID: UUID
            var messages: [Message]
            var artifacts: [Artifact]
            var status = "idle"
        }
        try JSONEncoder().encode(Snapshot(conversationID: UUID(), messages: messages, artifacts: [firstFile, secondFile]))
            .write(to: data.appendingPathComponent("chat.json"), options: .atomic)
        let chat = PicoChatStore(dataDir: data)
        precondition(chat.messages.map(\.id) == messages.map(\.id), "The private fixture must load its persisted rows")
        precondition(chat.unassignedArtifacts.isEmpty && chat.pendingArtifacts.isEmpty)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let host = FirstMouseHostingView(rootView: ChatArtifactFixture(chat: chat))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host; window.backgroundColor = .clear; window.isOpaque = false
        window.level = .floating; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.7)) }
        func capture(_ name: String) throws -> URL {
            window.contentView?.needsDisplay = true; window.displayIfNeeded(); settle()
            let path = output.appendingPathComponent(name + ".png")
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
            try task.run(); task.waitUntilExit()
            precondition(task.terminationStatus == 0, "Physical WindowServer capture is required for native UI acceptance")
            return path
        }
        func recognized(_ path: URL) throws -> [(text: String, rect: CGRect)] {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(url: path, options: [:]).perform([request])
            return (request.results ?? []).compactMap { result in
                guard let text = result.topCandidates(1).first?.string else { return nil }
                let box = result.boundingBox
                return (text, CGRect(x: box.minX * 560, y: (1 - box.maxY) * 720, width: box.width * 560, height: box.height * 720))
            }
        }
        func exactlyOne(_ needle: String, in rows: [(text: String, rect: CGRect)]) -> CGRect {
            let found = rows.filter { $0.text.contains(needle) }
            precondition(found.count == 1, "Expected exactly one rendered \(needle), got \(found.map(\.text)); OCR \(rows.map(\.text))")
            return found[0].rect
        }
        func inputTop() -> CGFloat {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let editor = descendants(host).compactMap { $0 as? NSTextView }
                .first { $0.accessibilityIdentifier() == "picoChatField" }!
            let scroll = editor.enclosingScrollView!
            let frame = scroll.convert(scroll.bounds, to: host)
            let top = host.isFlipped ? frame.minY : host.bounds.height - frame.maxY
            return top - 10 // Native editor sits inside the capsule's10pt padding.
        }
        func requireOrder(_ path: URL) throws {
            let rows = try recognized(path)
            let first = exactlyOne("FIRST OUTPUT READY", in: rows)
            let firstOutput = exactlyOne("alpha-note.md", in: rows)
            let firstFollowup = exactlyOne("FOLLOWUP AFTER FIRST OUTPUT", in: rows)
            let second = exactlyOne("SECOND OUTPUT READY", in: rows)
            let secondOutput = exactlyOne("beta-report.md", in: rows)
            let secondFollowup = exactlyOne("FOLLOWUP AFTER SECOND OUTPUT", in: rows)
            let latest = exactlyOne("LATEST FOLLOWUP HAS NO FILES", in: rows)
            precondition(first.maxY < firstOutput.minY && firstOutput.maxY < firstFollowup.minY,
                         "First output must remain between its reply and the next user message")
            precondition(second.maxY < secondOutput.minY && secondOutput.maxY < secondFollowup.minY,
                         "Second output must remain between its reply and the next user message")
            precondition(secondFollowup.maxY < latest.minY && latest.maxY < inputTop() - 8,
                         "Later replies must follow files, leaving no repeated files at the transcript footer")
            print("PASS physical message order: first reply→alpha→followup; second reply→beta→followup→latest; each file once")
        }
        try requireOrder(capture("owned-files-followups"))
        let reopened = PicoChatStore(dataDir: data)
        precondition(reopened.messages.first(where: { $0.id == firstOwner.id })?.artifacts?.first?.path == firstFile.path)
        precondition(reopened.messages.first(where: { $0.id == secondOwner.id })?.artifacts?.first?.path == secondFile.path)
        host.rootView = ChatArtifactFixture(chat: reopened)
        try requireOrder(capture("owned-files-reopened"))
        let search = reopened.searchMessages(firstFile.name)
        precondition(search.count == 1 && search[0].id == firstOwner.id, "Filename search must return the actual owning reply")
        host.rootView = ChatArtifactFixture(chat: reopened, query: firstFile.name)
        let searchRows = try recognized(capture("owned-file-search"))
        _ = exactlyOne("FIRST OUTPUT READY", in: searchRows)
        _ = exactlyOne("alpha-note.md", in: searchRows)
        precondition(!searchRows.contains(where: { $0.text.contains("beta-report.md") || $0.text.contains("LATEST FOLLOWUP") }))
        print("PASS reopened native layout and filename search retain file ownership; screenshots \(output.path)")
    }
}

private struct ChatArtifactFixture: View {
    @ObservedObject var chat: PicoChatStore
    var query = ""
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    var body: some View {
        PicoChatView(chat: chat, query: query)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(stops: [.init(color: .black.opacity(0.99), location: 0), .init(color: .black.opacity(0.97), location: 0.8), .init(color: .black.opacity(0.4), location: 1)], startPoint: .top, endPoint: .bottom), in: shape)
            .modifier(PanelGlass(shape: shape)).clipShape(shape)
            .environment(\.colorScheme, .dark).foregroundStyle(.white)
    }
}
