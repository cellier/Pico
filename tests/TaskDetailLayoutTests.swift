import AppKit
import SwiftUI

/// Exercise real hosting/layout without workers, app permissions or user data.
@main struct TaskDetailLayoutTests {
    @MainActor static func main() {
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("TelosLayout-" + UUID().uuidString)
        setenv("TELOS_DATA_DIR", data.path, 1)
        setenv("TELOS_PREVIEW", "detail", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let store = TaskStore()
        let paragraph = "Native layout must keep responding during long mixed-language messages. 中英文内容完整保留。\n"
        if let path = ProcessInfo.processInfo.environment["TELOS_LAYOUT_FIXTURE"] {
            let data = try! Data(contentsOf: URL(fileURLWithPath: path))
            let objects = try! JSONSerialization.jsonObject(with: data) as! [[String: Any]]
            let record = objects.first { ($0["id"] as? String)?.uppercased() == "99B046DF-F6EE-4E74-B29B-22B878109B95" }!
            store.tasks = [try! JSONDecoder().decode(Todo.self, from: JSONSerialization.data(withJSONObject: record))]
        } else {
            store.tasks[0].messages = [Message(role: "user", text: String(repeating: paragraph, count: 40))]
            for index in 0..<12 {
                store.tasks[0].messages.append(Message(role: "assistant", text: "Section \(index)\n" + String(repeating: paragraph, count: index % 4 + 2)))
            }
        }
        let id = store.tasks[0].id
        store.tasks[0].status = "running"
        store.selected = id
        let original = store.tasks[0].messages.map(\.text)
        // Initialize preview services before exercising the real running controls.
        // No AppDelegate or worker/runtime bundle is present in this test process.
        _ = CalendarStore.shared
        unsetenv("TELOS_PREVIEW")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 720), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TaskBoard(store: store))
        window.orderFront(nil)
        var finished = false
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 15)
        watchdog.setEventHandler {
            fputs("FAIL: native layout did not finish within 15 seconds\n", stderr)
            exit(70)
        }
        watchdog.resume()
        var tick = 0
        var previous = Date()
        var maximumDelay: TimeInterval = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = Date()
                maximumDelay = max(maximumDelay, now.timeIntervalSince(previous))
                previous = now
                tick += 1
                if tick <= 60 {
                    store.mutate(id) {
                        $0.messages.append(Message(role: "confirmation", text: "Automatically approved: local fixture step \(tick)"))
                        $0.summary = "Fixture step \(tick)"
                        $0.voicePhase = tick.isMultiple(of: 2) ? "working" : "thinking"
                    }
                    store.streams[id] = String(repeating: paragraph, count: min(60, tick))
                    if tick.isMultiple(of: 10) { store.selected = nil }
                    if tick % 10 == 1 { store.selected = id }
                } else if tick == 61 {
                    store.streams[id] = nil
                    store.mutate(id) {
                        $0.messages.append(Message(role: "assistant", text: String(repeating: paragraph, count: 60)))
                        $0.status = "ready"
                    }
                    store.selected = id
                } else if tick >= 85 { finished = true }
            }
        }
        while !finished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        timer.invalidate()
        watchdog.cancel()
        precondition(maximumDelay < 2, "Main run loop stalled for \(maximumDelay) seconds")
        precondition(Array(store.tasks[0].messages.prefix(original.count)).map(\.text) == original, "History must remain intact")
        precondition(store.tasks[0].messages.count == original.count + 61)
        precondition(store.tasks[0].status == "ready")
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: data)
        print("PASS: 60 confirmation/stream updates, detail reopen, long-message history and main-loop heartbeat; maximum delay \(maximumDelay)s")
    }
}
