import AppKit
import SwiftUI
import Vision

/// Native regression for Chat's real scroll geometry and floating composer.
/// It renders locally and sends events only to its own isolated test window.
@main struct PicoChatScrollTests {
    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let privateData = FileManager.default.temporaryDirectory.appendingPathComponent("pico-chat-scroll-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: privateData, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        setenv("TELOS_PREVIEW", "chat-long", 1)
        setenv("TELOS_DATA_DIR", privateData.path, 1)
        defer {
            try? FileManager.default.removeItem(at: privateData)
            for key in ["TELOS_PREVIEW", "TELOS_DATA_DIR"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/pico-chat-scroll-tests")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        setvbuf(stdout, nil, _IONBF, 0)
        let tasks = TaskStore()
        let chat = PicoChatStore(dataDir: privateData, taskStore: tasks)
        precondition(tasks.dataDir.standardizedFileURL.path == privateData.standardizedFileURL.path && chat.dataDir.standardizedFileURL.path == privateData.standardizedFileURL.path, "Native QA must never use the formal data store")
        precondition(chat.messages.count == 80 && chat.hasEarlierMessages, "Long Chat must retain its bounded message page")
        precondition(chat.messages.last?.text.contains("Conversation message 120.") == true)

        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(white: 0.6, alpha: 1)
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backdrop.center(); backdrop.orderFrontRegardless()
        let host = FirstMouseHostingView(rootView: PicoChatScrollFixture(chat: chat))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 374, height: 528), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.backgroundColor = .clear; window.isOpaque = false
        window.level = .floating; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); backdrop.orderOut(nil) }
        func settle(_ seconds: TimeInterval = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        func nativeViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(nativeViews) }
        func topRect(_ view: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: host)
            return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func editor() -> AttachmentTextView {
            nativeViews(host).compactMap { $0 as? AttachmentTextView }.first { $0.accessibilityIdentifier() == "picoChatField" }!
        }
        func editorRect() -> CGRect { topRect(editor().enclosingScrollView!) }
        func footer() -> (top: CGFloat, height: CGFloat) {
            // Composer has 10pt inner top padding and a16pt transparent gap.
            // Its NSTextView document can retain a taller frame after a draft
            // shrinks; the enclosing scroll viewport is the actual input size.
            let top = editorRect().minY - 26
            return (top, window.frame.height - 16 - top)
        }
        func arrowCenter() -> CGPoint {
            CGPoint(x: window.frame.width / 2, y: window.frame.height - 16 - max(48, footer().height - 8) - 11)
        }
        func maxOffset(_ scroll: NSScrollView) -> CGFloat {
            max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        }
        func scroll(_ view: NSScrollView, to y: CGFloat) {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
            view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: view)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
            settle()
        }
        func requireEnd(_ scroll: NSScrollView, context: String) {
            let actual = scroll.contentView.bounds.origin.y, end = maxOffset(scroll)
            precondition(end > 300, "The transcript must actually overflow: \(context)")
            precondition(actual >= -0.5 && actual <= end + 1, "Chat must never overscroll beyond its real content: \(context)")
            precondition(abs(actual - end) <= 2, "Chat must show its actual last message: \(context), actual \(actual), end \(end)")
        }
        func capture(_ name: String) throws -> URL {
            window.contentView?.needsDisplay = true; window.displayIfNeeded(); settle(0.15)
            let url = output.appendingPathComponent(name + ".png")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try process.run(); process.waitUntilExit()
            if process.terminationStatus != 0 {
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No native Chat capture available") }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                print("CAPTURE LIMIT: WindowServer denied \(name); used native hosting bitmap, which cannot verify live backdrop-glass appearance")
            }
            return url
        }
        func arrowInk(_ url: URL) throws -> Int {
            let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
            let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
            let center = arrowCenter()
            var whitePixels = 0
            for y in Int((center.y - 5) * scale)...Int((center.y + 5) * scale) {
                for x in Int((center.x - 6) * scale)...Int((center.x + 6) * scale) {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if min(color.redComponent, color.greenComponent, color.blueComponent) > 0.7 { whitePixels += 1 }
                }
            }
            return whitePixels
        }
        func pressLatest() -> Bool {
            let center = arrowCenter()
            let point = NSPoint(x: center.x, y: window.frame.height - center.y)
            func nodes(_ value: Any, depth: Int = 0) -> [NSAccessibilityProtocol] {
                guard depth < 14, let node = value as? NSAccessibilityProtocol else { return [] }
                return [node] + (node.accessibilityChildren() ?? []).flatMap { nodes($0, depth: depth + 1) }
            }
            var roots: [Any] = [host, window, app]
            if let hit = host.accessibilityHitTest(window.convertPoint(toScreen: point)) {
                roots.append(hit)
                var ancestor = hit as? NSAccessibilityProtocol
                for _ in 0..<6 {
                    guard let parent = ancestor?.accessibilityParent() else { break }
                    roots.append(parent); ancestor = parent as? NSAccessibilityProtocol
                }
            }
            if let button = roots.flatMap({ nodes($0) }).first(where: { $0.accessibilityLabel() == "Jump to latest message" && $0.accessibilityRole() == .button }) {
                let pressed = button.accessibilityPerformPress()
                print("CONTROL semantic latest press=\(pressed), frame=\(button.accessibilityFrame())")
                return pressed
            }
            // Route a real AppKit mouse pair only to this private test window.
            // Queue mouseUp first so native button tracking cannot block.
            let time = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: time + 0.02,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
            print("CONTROL own-window native mouse pair delivered; global pointer untouched")
            return true
        }
        func requireRenderedLatest(_ url: URL, scroll: NSScrollView) throws {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(url: url, options: [:]).perform([request])
            let lines = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                let rect = CGRect(x: box.minX * window.frame.width, y: (1 - box.maxY) * window.frame.height,
                                  width: box.width * window.frame.width, height: box.height * window.frame.height)
                return (text, rect)
            }
            guard let latest = lines.first(where: { $0.0.contains("Conversation message 120") }) else {
                fatalError("The last message must actually be rendered: \(lines.map { $0.0 })")
            }
            precondition(latest.1.maxY < footer().top - 4, "Latest message must remain above the floating composer")
            guard let lastContentLine = lines.filter({ $0.1.minY >= latest.1.minY && $0.0.contains("control") }).map({ $0.1.maxY }).max() else {
                fatalError("The final wrapped line of message120 must remain rendered")
            }
            precondition(lastContentLine < footer().top - 2, "Reserve must keep the final wrapped line above the footer")
        }
        func underpassDifference(_ before: URL, _ after: URL) throws -> Int {
            let first = NSBitmapImageRep(data: try Data(contentsOf: before))!
            let second = NSBitmapImageRep(data: try Data(contentsOf: after))!
            let scale = CGFloat(first.pixelsWide) / window.frame.width
            // Sample within the input capsule's vertical band. Input controls
            // stay fixed; changing pixels here come from scrolling underneath.
            let bounds = CGRect(x: 80, y: footer().top + 22, width: window.frame.width - 112, height: footer().height - 28)
            var changed = 0
            for y in Int(bounds.minY * scale)..<Int(bounds.maxY * scale) {
                for x in Int(bounds.minX * scale)..<Int(bounds.maxX * scale) {
                    let a = first.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let b = second.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let difference = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                    if difference > 0.06 { changed += 1 }
                }
            }
            return changed
        }

        settle(1.3)
        guard let transcript = scrollViews(host).filter({ $0.contentView.bounds.height > 100 }).max(by: { $0.bounds.width < $1.bounds.width }) else {
            fatalError("No native Chat transcript viewport")
        }
        // Check the initial end before any manual scrolling can conceal the bug.
        requireEnd(transcript, context: "initial opening")
        let initial = try capture("374x528-initial-latest")
        let initialInk = try arrowInk(initial)
        precondition(initialInk == 0, "The latest arrow must start hidden at the real end")
        try requireRenderedLatest(initial, scroll: transcript)

        var semanticPresses = 0
        for size in [NSSize(width: 374, height: 528), NSSize(width: 560, height: 720), NSSize(width: 340, height: 420)] {
            window.setContentSize(size); window.center(); window.orderFrontRegardless(); settle()
            precondition(transcript.contentView.bounds.origin.y <= maxOffset(transcript) + 1, "Resizing must never leave an invalid scroll position")
            precondition(abs(transcript.contentView.bounds.height - (size.height - 32)) < 1, "Chat viewport must continue behind the entire floating footer")
            let fixedEditor = editorRect()
            precondition(topRect(transcript).maxY > fixedEditor.maxY, "Transcript and composer must overlap vertically")
            scroll(transcript, to: maxOffset(transcript) / 2)
            let beforeUnderpass = try capture("\(Int(size.width))x\(Int(size.height))-footer-underpass-a")
            // Bubbles leave uniform gaps between messages; one short step can land a gap
            // under the capsule. Any of a few steps must show content moving beneath it.
            let underpassStart = transcript.contentView.bounds.origin.y
            var changed = 0
            for step in [8, 24, 40] as [CGFloat] where changed <= 24 {
                scroll(transcript, to: underpassStart + step)
                let afterUnderpass = try capture("\(Int(size.width))x\(Int(size.height))-footer-underpass-b\(Int(step))")
                changed = max(changed, try underpassDifference(beforeUnderpass, afterUnderpass))
            }
            precondition(changed > 24, "Scrolled text must visibly pass underneath the composer, not stop at its top")
            precondition(editorRect() == fixedEditor, "Scrolling must not move the composer")
            let readingOffset = transcript.contentView.bounds.origin.y
            editor().draft?.setText(String(repeating: "A longer local draft with a new line.\n", count: 5)); settle()
            precondition(editorRect().height > 50, "Native multiline editor must actually expand for this check")
            precondition(abs(transcript.contentView.bounds.origin.y - readingOffset) < 1, "Growing a draft must preserve a scrolled-away reading position")
            editor().draft?.setText(""); settle()
            scroll(transcript, to: 0)
            // Reaching the old page's top can prepend earlier messages.
            // Its previous first row remains anchored rather than jumping to0.
            precondition(transcript.contentView.bounds.origin.y >= -0.5 && transcript.contentView.bounds.origin.y <= maxOffset(transcript) + 1)
            let prefix = "\(Int(size.width))x\(Int(size.height))"
            let top = try capture(prefix + "-top-jump-visible")
            let visibleInk = try arrowInk(top)
            precondition(visibleInk > 8, "Scrolling away from the end must physically show the latest chevron")
            let pressed = pressLatest()
            settle(0.9)
            if pressed { semanticPresses += 1 }
            else { fatalError("The private native Jump action must be delivered") }
            requireEnd(transcript, context: prefix + " return to latest")
            let latest = try capture(prefix + "-latest")
            let latestInk = try arrowInk(latest)
            precondition(latestInk == 0, "Returning to the end must physically remove the latest chevron")
            try requireRenderedLatest(latest, scroll: transcript)
            editor().draft?.setText(String(repeating: "A longer local draft with a new line.\n", count: 5)); settle()
            requireEnd(transcript, context: prefix + " expanded composer")
            let expanded = try capture(prefix + "-latest-expanded-composer")
            try requireRenderedLatest(expanded, scroll: transcript)
            editor().draft?.setText(""); settle()
            requireEnd(transcript, context: prefix + " collapsed composer")
            print("PASS \(prefix): latest120 above footer; arrow visibility and native return; visible underpass changed\(changed)pixels; reading offset preserved; multiline input follows latest; viewport=\(transcript.contentView.bounds.height)")
        }
        let privateFiles = FileManager.default.enumerator(at: privateData, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        let regularFiles = try privateFiles.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        precondition(regularFiles.isEmpty, "Preview UI must not write transcript or task files")
        precondition(!chat.isRunning, "Scroll verification must never start a model request")
        print("PASS long Chat initial/end layout, native resize, transparent footer underpass, latest arrow visibility, multiline composer, private read-only preview; screenshots: \(output.path)")
        print("CONTROL coverage: actual semantic Jump presses=\(semanticPresses)/3; physical pointer delivery was not tested while locked")
    }
}

private struct PicoChatScrollFixture: View {
    let chat: PicoChatStore
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    var body: some View {
        ZStack(alignment: .top) {
            PicoChatView(chat: chat, headerInset: 60)
            HStack {
                Image(systemName: "magnifyingglass").frame(width: 36, height: 36)
                Spacer()
                HStack(spacing: 16) { Text("Chat").fontWeight(.semibold); Text("Tasks"); Text("Events") }.font(.system(size: 13))
                Spacer(); Text("Pico").font(.system(size: 10)).frame(width: 36, height: 36)
            }.frame(height: 36).contentShape(Rectangle()).onTapGesture {}
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(stops: [.init(color: .black.opacity(0.99), location: 0), .init(color: .black.opacity(0.97), location: 0.8), .init(color: .black.opacity(0.4), location: 1)], startPoint: .top, endPoint: .bottom), in: shape)
            .modifier(PanelGlass(shape: shape)).clipShape(shape)
            .environment(\.colorScheme, .dark).foregroundStyle(.white)
    }
}
