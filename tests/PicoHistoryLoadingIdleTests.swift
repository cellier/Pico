import AppKit
import SwiftUI

/// Standalone host regression for the production dot/history views. Compile
/// with their source slice; it does not link or launch the user's application.
private final class LayoutCount {
    var value = 0
}

private final class CountingHost<Content: View>: NSHostingView<Content> {
    let count: LayoutCount
    init(rootView: Content, count: LayoutCount) {
        self.count = count
        super.init(rootView: rootView)
    }
    required init(rootView: Content) { fatalError("Use the counting initializer") }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override func layout() {
        count.value += 1
        super.layout()
    }
}

private struct HistoryFixture: View {
    var loading: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                PicoHistoryLoading(label: "Earlier messages", action: {}, isLoading: loading)
                ForEach(0..<160, id: \.self) { index in
                    Text("Historical message \(index)")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                PicoHistoryLoading(label: "Later messages", action: {}, isLoading: loading)
            }
        }.frame(width: 360, height: 240)
    }
}

@main struct PicoHistoryLoadingIdleTests {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let count = LayoutCount()
        let host = CountingHost(rootView: HistoryFixture(loading: false), count: count)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 360, height: 240),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = host
        // Render the test host without taking keyboard focus from any real app.
        window.orderFront(nil)
        defer { window.orderOut(nil); window.close() }
        func advance(_ duration: TimeInterval) {
            let end = Date().addingTimeInterval(duration)
            while Date() < end {
                RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01)))
            }
        }
        func layouts(over duration: TimeInterval) -> Int {
            count.value = 0
            advance(duration)
            return count.value
        }
        host.layoutSubtreeIfNeeded()
        advance(0.7)
        let idle = layouts(over: 1)
        host.rootView = HistoryFixture(loading: true)
        advance(0.7)
        let animating = layouts(over: 1)
        host.rootView = HistoryFixture(loading: false)
        advance(0.7)
        let stopped = layouts(over: 1)
        precondition(idle <= 5, "Available offscreen history must not keep laying out: \(idle)")
        precondition(animating > max(5, idle + 5), "Positive control must still animate: \(animating)")
        precondition(stopped <= 5, "Ending loading must cancel its animation task: \(stopped)")
        print("PASS: idle layouts=\(idle), animated=\(animating), stopped=\(stopped)")
    }
}
