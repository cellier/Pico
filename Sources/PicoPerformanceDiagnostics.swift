#if TELOS_DIAGNOSTICS
import AppKit
import QuartzCore

/// Drives the main window through a resize sweep and a scroll sweep and records how long the main
/// thread spends on each frame (layout, display and the Core Animation commit). Diagnostics only.
@MainActor enum PicoPerformanceDiagnostics {
    struct Series: Codable {
        var name: String
        var frames: Int
        var medianMs: Double
        var p95Ms: Double
        var maxMs: Double
        var over16ms: Int
        var over33ms: Int
        var firstFramesMs: [Double] = []
    }

    static func run(window: NSWindow, output: URL) async {
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        // TELOS_PERF_FRAME="x y w h" places the window first (e.g. a user's saved frame).
        if let spec = ProcessInfo.processInfo.environment["TELOS_PERF_FRAME"]?.split(separator: " ").compactMap({ Double($0) }), spec.count == 4 {
            window.setFrame(NSRect(x: spec[0], y: spec[1], width: spec[2], height: spec[3]), display: true)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        var results: [Series] = []
        let only = ProcessInfo.processInfo.environment["TELOS_PERF_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func wants(_ phase: String) -> Bool { only?.contains(phase) ?? true }
        let start = window.frame
        if wants("liveresize") {
            log("liveresize start")
            results.append(await liveResize(window))
            log("liveresize done")
            window.setFrame(start, display: true)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        if wants("resize") {
            log("resize start")
            results.append(await resize(window, from: start))
            log("resize done")
        }
        window.setFrame(start, display: true)
        try? await Task.sleep(nanoseconds: 800_000_000)
        if wants("scroll"), let scrollView = largestScrollView(in: window.contentView) {
            log("scroll start: \(type(of: scrollView)) document \(Int(scrollView.documentView?.frame.height ?? 0)) visible \(Int(scrollView.contentView.bounds.height)) chat \(textView(identifier: "picoChatField", in: scrollView.superview?.superview?.superview) != nil)")
            results.append(await scroll(scrollView, window: window, name: "scroll"))
            log("scroll done")
        }
        if wants("typing"), let editor = textView(identifier: "picoChatField", in: window.contentView) {
            log("typing start")
            results.append(await typing(editor, window: window))
            log("typing done")
        }
        if wants("stream") {
            log("stream start")
            results.append(await stream())
            log("stream done")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(results).write(to: output)
        NSApp.terminate(nil)
    }

    /// A real corner drag through AppKit's live-resize tracking loop. The mouse-down goes to the
    /// window, which starts tracking; drags and the mouse-up are queued from a background thread
    /// into the app's event queue, where the tracking loop reads them. The pointer does not move.
    private static func liveResize(_ window: NSWindow) async -> Series {
        let frame = window.frame
        let corner = NSPoint(x: frame.width - 2, y: 2)   // bottom-right, window coordinates
        let number = window.windowNumber
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: number, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        var lateness: [Double] = []
        var widest: CGFloat = 0
        var sawLiveResize = false
        var expected = CACurrentMediaTime() + 0.016
        let probe = Timer(timeInterval: 0.016, repeats: true) { _ in
            let now = CACurrentMediaTime()
            lateness.append(max(0, now - expected) * 1000)
            expected = now + 0.016
            widest = max(widest, window.frame.width); sawLiveResize = sawLiveResize || window.inLiveResize
        }
        RunLoop.main.add(probe, forMode: .common)
        DispatchQueue.global().async {
            usleep(100_000)
            // Fine sweep (TELOS_PERF_SWEEP=fine): 2 pt steps across 500 pt, out and back twice.
            let fine = ProcessInfo.processInfo.environment["TELOS_PERF_SWEEP"] == "fine"
            let steps = fine ? 1000 : 150
            for step in 1...steps {
                let t = Double(step) / Double(steps) * 2 * .pi * (fine ? 2 : 1)
                // TELOS_PERF_SHRINK drags inward past the minimum size instead of outward.
                let inward = ProcessInfo.processInfo.environment["TELOS_PERF_SHRINK"] != nil
                let span: (CGFloat, CGFloat) = inward ? (-260, -260) : fine ? (500, 300) : (240, 200)
                let point = NSPoint(x: corner.x + span.0 * (0.5 - 0.5 * cos(t)), y: corner.y - span.1 * (0.5 - 0.5 * cos(t)))
                if let e = event(.leftMouseDragged, point) { NSApp.postEvent(e, atStart: false) }
                usleep(16_000)
            }
            if let e = event(.leftMouseUp, corner) { NSApp.postEvent(e, atStart: false) }
        }
        if let down = event(.leftMouseDown, corner) { window.sendEvent(down) }   // returns when tracking ends
        try? await Task.sleep(nanoseconds: 300_000_000)
        probe.invalidate()
        log("liveresize widened by \(Int(widest - frame.width)) pt, inLiveResize seen \(sawLiveResize)")
        return summarize("liveresize", lateness.map { $0 + 16.6 })
    }

    /// Width and height sweep like a user dragging the corner: 240 frames.
    private static func resize(_ window: NSWindow, from start: NSRect) async -> Series {
        var samples: [Double] = []
        // Mirror a user drag: AppKit brackets it with live-resize notifications.
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: window)
        defer { NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        for step in 0..<240 {
            let t = Double(step) / 240 * 2 * .pi
            let width = start.width + 260 * (0.5 - 0.5 * cos(t))
            let height = start.height + 220 * (0.5 - 0.5 * cos(t))
            let frame = NSRect(x: start.minX, y: start.maxY - height, width: width, height: height)
            let began = CACurrentMediaTime()
            window.setFrame(frame, display: true)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            samples.append((CACurrentMediaTime() - began) * 1000)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        return summarize("resize", samples)
    }

    /// Scrolls up through history and back down, 24 points per frame, by moving the clip view.
    private static func scroll(_ scrollView: NSScrollView, window: NSWindow, name: String) async -> Series {
        var samples: [Double] = []
        let clip = scrollView.contentView
        let startOffset = clip.bounds.origin.y
        var travel: CGFloat = 0
        defer { log("scroll travelled \(Int(travel)) pt") }
        // A trackpad gesture is bracketed by live-scroll notifications; the chat uses
        // them to stop following the latest message while the user reads history.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        defer { NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView) }
        for step in 0..<300 {
            let delta: CGFloat = step < 150 ? -24 : 24
            var origin = clip.bounds.origin
            origin.y = max(0, origin.y + (clip.isFlipped ? delta : -delta))
            let began = CACurrentMediaTime()
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            samples.append((CACurrentMediaTime() - began) * 1000)
            try? await Task.sleep(nanoseconds: 16_000_000)
            travel = max(travel, abs(clip.bounds.origin.y - startOffset))
        }
        return summarize(name, samples)
    }

    /// Streams a growing multi-paragraph reply in 40 ms flushes (the worker's coalescing interval)
    /// while a 16 ms timer measures how late the main thread lets it fire.
    private static func stream() async -> Series {
        guard let chat = PicoChatStore.diagnosticsInstance else { return summarize("stream", [0]) }
        let words = PicoChatStore.performanceTranscript(count: 12).map(\.text).joined(separator: "\n\n").split(separator: " ")
        var lateness: [Double] = []
        var expected = CACurrentMediaTime() + 0.016
        let probe = Timer(timeInterval: 0.016, repeats: true) { _ in
            let now = CACurrentMediaTime()
            lateness.append(max(0, now - expected) * 1000)
            expected = now + 0.016
        }
        RunLoop.main.add(probe, forMode: .common)
        var text = ""
        for (index, word) in words.prefix(500).enumerated() {
            text += (index == 0 ? "" : " ") + word
            if index % 2 == 1 {
                chat.diagnosticsStream(text, running: true)
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        probe.invalidate()
        chat.diagnosticsStream("", running: false)
        // Report lateness as frame time: a timer that fires 20 ms late means a 36 ms frame.
        return summarize("stream", lateness.map { $0 + 16.6 })
    }

    /// Types 120 characters into the chat composer at 50 ms intervals (a fast typist) while the
    /// 16 ms probe measures main-thread lateness.
    private static func typing(_ editor: NSTextView, window: NSWindow) async -> Series {
        window.makeFirstResponder(editor)
        let text = Array("这个方案我看了，整体可以，但数据迁移那块需要再确认一下 rollout plan and the owner before Friday. ")
        var lateness: [Double] = []
        var expected = CACurrentMediaTime() + 0.016
        let probe = Timer(timeInterval: 0.016, repeats: true) { _ in
            let now = CACurrentMediaTime()
            lateness.append(max(0, now - expected) * 1000)
            expected = now + 0.016
        }
        RunLoop.main.add(probe, forMode: .common)
        for index in 0..<120 {
            editor.insertText(String(text[index % text.count]), replacementRange: editor.selectedRange())
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        probe.invalidate()
        editor.string = ""; editor.didChangeText()
        return summarize("typing", lateness.map { $0 + 16.6 })
    }

    private static func textView(identifier: String, in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        var stack = [view]
        while let next = stack.popLast() {
            if let text = next as? NSTextView, text.accessibilityIdentifier() == identifier { return text }
            stack.append(contentsOf: next.subviews)
        }
        return nil
    }

    private static func log(_ text: String) {
        FileHandle.standardError.write(Data("[perf \(String(format: "%.1f", CACurrentMediaTime()))] \(text)\n".utf8))
    }

    private static func largestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        var stack = [view]
        while let next = stack.popLast() {
            if let scroll = next as? NSScrollView, !scroll.isHidden, scroll.alphaValue > 0,
               (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            stack.append(contentsOf: next.subviews)
        }
        return best
    }

    private static func summarize(_ name: String, _ samples: [Double]) -> Series {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        return Series(name: name, frames: samples.count, medianMs: percentile(0.5), p95Ms: percentile(0.95),
                      maxMs: sorted.last ?? 0, over16ms: samples.filter { $0 > 16.7 }.count,
                      over33ms: samples.filter { $0 > 33.4 }.count, firstFramesMs: Array(samples.prefix(5)))
    }
}
#endif
