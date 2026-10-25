import AppKit
import SwiftUI
import Vision

/// The production Chat view, with ten thousand private persisted messages and
/// eighty very long replies. No worker, external app or global pointer is used.
@main struct PicoChatLazyScaleUITests {
    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("pico-lazy-scale-" + UUID().uuidString)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/pico-chat-lazy-scale-tests")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        unsetenv("TELOS_PREVIEW"); setenv("TELOS_DATA_DIR", data.path, 1)
        defer {
            try? FileManager.default.removeItem(at: data)
            for key in ["TELOS_PREVIEW", "TELOS_DATA_DIR"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setvbuf(stdout, nil, _IONBF, 0)
        let huge = String(repeating: "中文 mixed English long paragraph for lazy layout.\n", count: 2300)
        precondition(huge.count > 100_000)
        var messages = (0..<10_000).map { index in
            Message(role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: index >= 9920 ? "MESSAGE \(index) BEGIN\n" + huge + "\nMESSAGE \(index) END"
                        : "Earlier short message \(index).")
        }
        messages[messages.count - 1].text += "\nLATEST LAST LINE"
        struct Snapshot: Encodable {
            var conversationID: UUID
            var messages: [Message]
            var artifacts: [Artifact] = []
            var status = "idle"
        }
        let persisted = try JSONEncoder().encode(Snapshot(conversationID: UUID(), messages: messages))
        let snapshot = data.appendingPathComponent("chat.json")
        try persisted.write(to: snapshot)
        let chat = PicoChatStore(dataDir: data)
        precondition(chat.totalMessageCount == 10_000 && chat.messages.count == 80 && !chat.isRunning)
        let allInitialRows = PicoChatTimelineRows.build(messages: chat.messages).count
        precondition(allInitialRows > 3000, "The fixture must contain thousands of independently lazy chunks")

        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let host = FirstMouseHostingView(rootView: PicoChatLazyScaleFixture(chat: chat))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 374, height: 528), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.isOpaque = false; window.backgroundColor = .clear
        window.level = .floating; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        func settle(_ duration: Double = 0.8) { RunLoop.main.run(until: Date().addingTimeInterval(duration)) }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func controller() -> PicoChatScrollController {
            descendants(host).compactMap { ($0 as? PicoChatScrollProbeView)?.controller }.first!
        }
        func transcript() -> NSScrollView {
            descendants(host).compactMap { $0 as? NSScrollView }.first { $0.contentView.bounds.height > 200 }!
        }
        func frames() -> [String: CGRect] {
            // Read-only test reflection avoids adding a diagnostic API to the app.
            Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
        }
        func nativePosition() -> (offset: CGFloat, origin: CGFloat, viewport: CGFloat, maximum: CGFloat) {
            let scroll = transcript(), document = scroll.documentView!
            let clip = scroll.contentView.bounds
            let probe = descendants(host).compactMap { $0 as? PicoChatScrollProbeView }.first!
            let rect = probe.convert(probe.bounds, to: document)
            return (document.isFlipped ? clip.minY : document.bounds.maxY - clip.maxY,
                    document.isFlipped ? rect.minY : document.bounds.maxY - rect.maxY,
                    clip.height, max(0, document.bounds.height - clip.height))
        }
        func actualAnchor() -> PicoChatScrollController.Anchor? {
            let position = nativePosition()
            let top = position.offset - position.origin
            let visible = frames().filter { $0.key != "picoLatest" && $0.value.maxY > top + 0.5 && $0.value.minY < top + position.viewport }
            guard let first = visible.min(by: { $0.value.minY == $1.value.minY ? $0.key < $1.key : $0.value.minY < $1.value.minY }) else { return nil }
            return .init(id: first.key, offset: top - first.value.minY)
        }
        func waitUntil(_ context: String, timeout: Double = 12, _ predicate: () -> Bool) {
            let start = Date()
            var stable = 0
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                stable = predicate() ? stable + 1 : 0
                if stable >= 3 {
                    print("SETTLED \(context) in \(String(format: "%.3f", Date().timeIntervalSince(start)))s")
                    return
                }
            } while Date().timeIntervalSince(start) < timeout
            fatalError("Timed out waiting for \(context); actual anchor \(String(describing: actualAnchor()))")
        }
        func atLatest() -> Bool {
            guard let tail = frames()["picoLatest"] else { return false }
            let position = nativePosition()
            let target = min(position.maximum, max(0, position.origin + tail.maxY - position.viewport))
            return controller().followingLatest && abs(position.offset - target) <= 2
        }
        func requireBounded(_ context: String) {
            let realized = frames().filter { $0.key != "picoLatest" }.count
            precondition(realized > 0 && realized < 128 && realized < allInitialRows / 10,
                         "Lazy Chat mounted too many chunks: \(context), tracked \(realized)/\(allInitialRows)")
            precondition(chat.messages.count <= 240 && chat.totalMessageCount == 10_000 && !chat.isRunning)
            print("PASS \(context): tracked realized chunks \(realized)/\(allInitialRows); loaded messages \(chat.messages.count)/10000")
        }
        func userScroll(to fraction: CGFloat) {
            let scroll = transcript()
            let document = scroll.documentView!
            let end = max(0, document.bounds.height - scroll.contentView.bounds.height)
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            let y = end * fraction
            let point = NSPoint(x: 0, y: document.isFlipped ? y : document.bounds.maxY - scroll.contentView.bounds.height - y)
            scroll.contentView.scroll(to: point); scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            waitUntil("user reading position") { !controller().followingLatest && actualAnchor() != nil }
        }
        func captureLatest(_ name: String) throws {
            let path = output.appendingPathComponent(name + ".png")
            window.displayIfNeeded(); settle(0.15)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0, "WindowServer capture is required; no bitmap fallback")
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
            try VNImageRequestHandler(url: path, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            precondition(lines.contains { $0.contains("LATEST LAST LINE") }, "The true last line must be visible: \(lines)")
        }

        settle(0.5)
        waitUntil("initial latest") { atLatest() }
        requireBounded("initial 80 huge replies")
        try captureLatest("374x528-initial-latest")
        userScroll(to: 0.55)
        requireBounded("reading middle of huge history")
        guard let before = controller().prepareForChange() else { fatalError("Reading history must capture a stable row anchor") }
        userScroll(to: 0.75)
        controller().restore(before)
        waitUntil("same-width return to previously realized chunk") {
            guard let actual = actualAnchor() else { return false }
            return actual.id == before.id && abs(actual.offset - before.offset) <= 2
        }
        requireBounded("same-width lazy chunk reappearance")
        chat.loadEarlier(); controller().restore(before)
        waitUntil("prepend anchor") { actualAnchor()?.id == before.id && abs((actualAnchor()?.offset ?? .infinity) - before.offset) <= 2 }
        guard let after = controller().prepareForChange() else { fatalError("Prepending history lost the reading anchor") }
        precondition(after.id == before.id && abs(after.offset - before.offset) <= 2,
                     "Prepend must preserve message chunk and intra-row offset: \(before)→\(after)")
        requireBounded("prepend preserves anchor")
        for size in [CGSize(width: 560, height: 720), CGSize(width: 340, height: 420), CGSize(width: 374, height: 528)] {
            let anchor = controller().prepareForChange()!
            window.setContentSize(size)
            waitUntil("resize \(Int(size.width)) anchor") {
                guard let current = actualAnchor(), let frame = frames()[anchor.id] else { return false }
                return current.id == anchor.id && abs(current.offset - min(anchor.offset, max(0, frame.height - 1))) <= 2
            }
            let resized = controller().prepareForChange()!
            let anchorFrame = frames()[anchor.id]
            let expectedOffset = min(anchor.offset, max(0, (anchorFrame?.height ?? 1) - 1))
            print("ANCHOR resize \(Int(size.width)): before \(anchor), after \(resized), expectedOffset \(expectedOffset), oldID frame \(String(describing: anchorFrame))")
            precondition(resized.id == anchor.id && abs(resized.offset - expectedOffset) <= 2,
                         "Resize must preserve reading position: \(anchor)→\(resized), expected offset \(expectedOffset), old frame \(String(describing: anchorFrame))")
            requireBounded("resize \(Int(size.width)) reading position")
            chat.showLatest(); controller().followLatest()
            waitUntil("resize \(Int(size.width)) latest") { atLatest() }
            requireBounded("resize \(Int(size.width)) latest")
            try captureLatest("\(Int(size.width))x\(Int(size.height))-latest")
            userScroll(to: 0.55)
        }
        let finalSnapshot = try Data(contentsOf: snapshot)
        precondition(finalSnapshot == persisted, "Native lazy QA must not rewrite the persisted history")
        print("PASS actual PicoChatView:10k history,80x100k+ messages, bounded lazy chunks, prepend/resize anchors, physically visible true latest; screenshots \(output.path)")
    }
}

private struct PicoChatLazyScaleFixture: View {
    @ObservedObject var chat: PicoChatStore
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    var body: some View {
        PicoChatView(chat: chat, headerInset: 60)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(stops: [.init(color: .black.opacity(0.99), location: 0), .init(color: .black.opacity(0.97), location: 0.8), .init(color: .black.opacity(0.4), location: 1)], startPoint: .top, endPoint: .bottom), in: shape)
            .modifier(PanelGlass(shape: shape)).clipShape(shape)
            .environment(\.colorScheme, .dark).foregroundStyle(.white)
    }
}
