import AppKit
import SwiftUI
import CoreText
import Vision

/// Exercise the real floating-window shell with private, inert preview data.
/// Direct clip-view scrolling avoids physical input and never calls a worker.
@main struct PicoTaskDetailUITests {
    @MainActor static func main() throws {
        let environment = ProcessInfo.processInfo.environment
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("pico-detail-ui-" + UUID().uuidString)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/pico-task-detail-ui-tests")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        setenv("TELOS_DATA_DIR", data.path, 1)
        defer {
            try? FileManager.default.removeItem(at: data)
            for key in ["TELOS_DATA_DIR", "TELOS_PREVIEW", "TELOS_PREVIEW_LONG"] {
                if let value = environment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        setvbuf(stdout, nil, _IONBF, 0)
        if let font = Bundle.main.url(forResource: "InstrumentSerif-Regular", withExtension: "ttf") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        let backdrop = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(white: 0.6, alpha: 1)
        backdrop.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        backdrop.center(); backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }
        func settle(_ seconds: TimeInterval = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func end(_ scroll: NSScrollView) -> CGFloat { max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height) }
        func scroll(_ view: NSScrollView, to y: CGFloat) {
            // Native clip scrolling can briefly be corrected as LazyVStack
            // remeasures after a resize. Settle that bounded layout work before
            // asserting the exact requested offset, as the end check already does.
            // Bracket the move as a live scroll, as a trackpad gesture does: the
            // timeline treats unbracketed clip moves as layout and keeps following latest.
            for attempt in 0..<5 {
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: view)
                view.contentView.scroll(to: NSPoint(x: 0, y: y)); view.reflectScrolledClipView(view.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: view)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: view)
                settle()
                if abs(view.contentView.bounds.origin.y - y) < 0.5 { break }
                print("SCROLL SETTLE", attempt, "requested", y, "observed", view.contentView.bounds.origin.y)
            }
        }
        func topRect(_ view: NSView, in host: NSView) -> CGRect {
            let rect = view.convert(view.bounds, to: host)
            return host.isFlipped ? rect : CGRect(x: rect.minX, y: host.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        }
        func capture(_ window: NSWindow, _ name: String) throws -> URL {
            window.contentView?.needsDisplay = true; window.displayIfNeeded(); settle(0.1)
            let path = output.appendingPathComponent(name + ".png")
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-o", "-l", String(window.windowNumber), path.path]
            try task.run(); task.waitUntilExit()
            if task.terminationStatus != 0 {
                guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    fatalError("Neither WindowServer nor native hosting-view capture is available")
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: path)
                print("CAPTURE LIMIT: WindowServer denied \(name); used native hosting-view bitmap, which cannot establish backdrop-glass appearance")
            }
            return path
        }
        func requireMarker(_ url: URL, expected: String) throws {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(url: url, options: [:]).perform([request])
            let recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            precondition(recognized.contains(expected), "Expected content must be rendered and readable: \(url.lastPathComponent), OCR=\(recognized)")
        }

        for fixture in ["normal", "long", "meeting", "meeting-live", "approval"] {
            setenv("TELOS_PREVIEW", fixture == "normal" || fixture == "long" ? "detail" : fixture, 1)
            unsetenv("TELOS_PREVIEW_LONG")
            let store = TaskStore()
            precondition(store.dataDir.standardizedFileURL.path == data.standardizedFileURL.path)
            precondition(store.selectedTask != nil, "Fixture must open the real task detail")
            let marker: String
            if fixture == "meeting" || fixture == "meeting-live" {
                let id = store.selectedTask!.meetingID!
                var meeting = store.meetings[id]!
                meeting.title = "Troubleshooting Google Account Authorization 403 Error"
                meeting.transcriptionEngine = "Bailian · qwen-audio-3.1-asr-flash-streaming · Cloud audio"
                meeting.transcript = []
                for index in 0..<18 {
                    let start = Double(index) * 12
                    let speaker: SpeakerSource = index % 2 == 0 ? .me : .others
                    let text = index == 17 ? "Final meeting line verified." : "Transcript segment \(index + 1). Review the account authorization error and confirm the next action."
                    let segment = TranscriptSegment(startTime: start, endTime: start + 8, speakerSource: speaker, text: text, isFinal: true)
                    meeting.transcript.append(segment)
                }
                store.meetings[id] = meeting
                marker = "Final meeting line verified"
            } else {
                let index = store.tasks.firstIndex { $0.id == store.selected }!
                if fixture == "normal" || fixture == "long" {
                    let paragraph = "Review the original requirements, confirm the account settings, and prepare the revised plan. Every paragraph remains readable while scrolling.\n\n"
                    store.tasks[index].messages = [Message(role: "user", text: "Please review this task."),
                                                  Message(role: "assistant", text: String(repeating: paragraph, count: fixture == "long" ? 14 : 2) + "Final task line verified.")]
                }
                marker = fixture == "approval" ? "Approve once" : "Final task line verified"
            }
            let host = NSHostingView(rootView: RootView(store: store))
            host.sizingOptions = []; host.safeAreaRegions = []
            let window = TelosWindow(contentRect: NSRect(x: 0, y: 0, width: 374, height: 528), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
            window.contentView = host; window.backgroundColor = .clear; window.isOpaque = false
            window.level = .floating; window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            settle(0.8)
            let sizes = fixture == "long" || fixture == "meeting" || fixture == "approval"
                ? [NSSize(width: 374, height: 528), NSSize(width: 340, height: 420), NSSize(width: 560, height: 720)]
                : [NSSize(width: 374, height: 528)]
            for size in sizes {
                window.setContentSize(size); window.center(); window.orderFrontRegardless(); settle(0.6)
                let isMeeting = fixture == "meeting" || fixture == "meeting-live"
                // Figma 349:5711: sheet begins56pt from the window top;
                // meetings reserve the25pt handle, ordinary chat passes below it.
                let expectedTop: CGFloat = isMeeting ? 81 : 56
                let candidates = views(host).compactMap { $0 as? NSScrollView }.filter {
                    let rect = topRect($0, in: host)
                    return abs(rect.minY - expectedTop) < 3 && abs(rect.width - size.width) < 3
                }
                guard let transcript = candidates.max(by: { $0.bounds.height < $1.bounds.height }) else {
                    for view in views(host).compactMap({ $0 as? NSScrollView }) { print("SCROLL", fixture, size, topRect(view, in: host), view.contentView.bounds) }
                    fatalError("No full-width task detail transcript at the design's sheet top")
                }
                let transcriptRect = topRect(transcript, in: host)
                precondition(abs(transcriptRect.minY - expectedTop) < 2, "Sheet top56 and overlay handle must not retain the old inset slab")
                precondition(abs(transcriptRect.minX) < 1 && abs(transcriptRect.width - size.width) < 2, "Detail sheet must span the whole window width")
                precondition(transcriptRect.height > 65 && transcriptRect.maxY <= size.height + 1, "Detail viewport must fit even the minimum window")
                let editor = views(host).compactMap { $0 as? NSTextView }.first { $0.accessibilityIdentifier() == "askField" }
                let editorRect = editor.map { topRect($0, in: host) }
                if !isMeeting {
                    precondition(editorRect != nil, "Ordinary task detail must retain its native composer")
                    if fixture == "approval" {
                        precondition(transcriptRect.maxY <= editorRect!.minY + 1, "Approval content must retain its space above the composer")
                    } else {
                        precondition(abs(transcriptRect.maxY - size.height) < 2, "Ordinary transcript must continue behind the floating composer")
                    }
                    precondition(editorRect!.maxY < size.height - 16, "Composer must remain inside the card")
                }
                let stem = "\(fixture)-\(Int(size.width))x\(Int(size.height))"
                scroll(transcript, to: 0)
                precondition(abs(transcript.contentView.bounds.origin.y) < 0.5)
                let top = try capture(window, stem + "-top")
                if fixture == "approval" {
                    try requireMarker(top, expected: "Approve once")
                    try requireMarker(top, expected: "Deny")
                    try requireMarker(top, expected: "Telos Harness Fixture")
                    let reasonHeight = views(host).compactMap { $0 as? NSScrollView }.filter {
                        let rect = topRect($0, in: host)
                        return !($0.documentView is NSTextView) && rect.minY >= transcriptRect.maxY && rect.maxY < editorRect!.minY && rect.width < transcriptRect.width
                    }.map { $0.contentView.bounds.height }.max() ?? 0
                    precondition(reasonHeight >= 28, "Approval must retain a visible scrolling reason, even at the minimum window")
                }
                if fixture == "long" && size.width == 374 {
                    scroll(transcript, to: end(transcript) / 2)
                    let offset = transcript.contentView.bounds.origin.y; settle()
                    precondition(abs(transcript.contentView.bounds.origin.y - offset) < 0.5, "Edge drawing must not move the scroll position")
                    _ = try capture(window, stem + "-middle")
                }
                for _ in 0..<4 { scroll(transcript, to: end(transcript)) }
                precondition(abs(transcript.contentView.bounds.origin.y - end(transcript)) < 1, "Must reach the real final content")
                let bottom = try capture(window, stem + "-bottom")
                try requireMarker(bottom, expected: marker)
                if let editor, let editorRect {
                    precondition(topRect(editor, in: host) == editorRect, "Scrolling transcript must not move or resize composer")
                }
                print("PASS \(stem): top=\(expectedTop), full-width transcript=\(transcriptRect), editor=\(String(describing: editorRect)), end=\(end(transcript)); last content rendered and readable")
            }
            window.orderOut(nil)
            precondition(store.selectedTask != nil && store.tasks.count > 0, "Layout verification must not dismiss or complete a task")
        }
        let files = FileManager.default.enumerator(at: data, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        let regularFiles = try files.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        precondition(regularFiles.isEmpty, "Private previews must never persist tasks, transcripts, or worker output")
        print("PASS native task-detail fixtures, direct scrolling, minimum/default/large layouts, stable footer, private read-only data; screenshots: \(output.path)")
    }
}
