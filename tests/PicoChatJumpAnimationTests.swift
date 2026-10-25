import AppKit
import SwiftUI

/// Actual native clip motion, without a visible app or account/model access.
@main struct PicoChatJumpAnimationTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var reduced = false
        let controller = PicoChatScrollController(reduceMotion: { reduced })
        let document = JumpDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 6000))
        let probe = PicoChatScrollProbeView(frame: NSRect(x: 0, y: 80, width: 400, height: 5920))
        probe.controller = controller; document.addSubview(probe)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.borderType = .noBorder; scroll.hasVerticalScroller = false
        scroll.autoresizingMask = [.width, .height]; scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.orderOut(nil) }
        var proxyTargets: [String] = []
        var finishes = 0
        var cancellations = 0
        controller.configure { id, _ in proxyTargets.append(id) }
        controller.onLatestAnimationFinished = { finishes += 1 }
        controller.onLatestAnimationCancelled = { cancellations += 1 }
        var rowPrefix: CGFloat = 0
        func recordFrames() {
            for index in 0..<10 {
                controller.record(id: "row\(index)", frame: NSRect(x: 0, y: CGFloat(index) * 500 + rowPrefix, width: scroll.bounds.width, height: 500))
            }
            controller.record(id: "picoLatest", frame: NSRect(x: 0, y: document.bounds.height - 160, width: scroll.bounds.width, height: 80))
        }
        func run(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func move(_ y: CGFloat) {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        }
        func grow(_ height: CGFloat) {
            document.setFrameSize(NSSize(width: scroll.bounds.width, height: height))
            probe.setFrameSize(NSSize(width: scroll.bounds.width, height: height - 80))
            recordFrames(); controller.contentChanged()
        }
        func maximum() -> CGFloat { document.bounds.height - scroll.contentView.bounds.height }
        func close(_ actual: CGFloat, _ expected: CGFloat, _ label: String) {
            precondition(abs(actual - expected) < 0.6, "\(label): got \(actual), expected \(expected)")
        }
        func sampleUntilDone() -> [CGFloat] {
            let deadline = Date().addingTimeInterval(2.8)
            var points = [scroll.contentView.bounds.minY]
            while controller.isAnimatingLatest && Date() < deadline {
                run(0.008)
                points.append(scroll.contentView.bounds.minY)
                precondition(scroll.contentView.bounds.minY >= -0.5 && scroll.contentView.bounds.minY <= maximum() + 0.5,
                             "An explicit jump must never overscroll the real document")
            }
            precondition(!controller.isAnimatingLatest, "The native animation must finish in bounded time")
            run(0.08)
            return points
        }
        recordFrames(); probe.attachSoon(); run(0.24)
        close(scroll.contentView.bounds.minY, 5700, "Initial automatic positioning remains immediate")
        precondition(!controller.isAnimatingLatest)

        move(700); run(0.05)
        proxyTargets.removeAll()
        controller.followLatest(animated: true)
        close(scroll.contentView.bounds.minY, 700, "Click retains its actual start rather than instantly proxy scrolling")
        let points = sampleUntilDone()
        let distinct = Set(points.map { Int(($0 * 10).rounded()) })
        precondition(distinct.count > 10, "A visible jump needs many intermediate native positions")
        precondition(zip(points, points.dropFirst()).allSatisfy { $1 >= $0 - 0.1 }, "The spring must travel toward the bottom without bouncing backward")
        precondition(!proxyTargets.contains("picoLatest"), "A synchronous scrollTo must not short-circuit explicit animation")
        close(scroll.contentView.bounds.minY, maximum(), "Animated actual end")
        precondition(finishes == 1)
        print("PASS explicit jump: \(distinct.count) distinct native positions, no proxy teleport or overscroll, exact bottom")

        move(300); run(0.05)
        controller.followLatest(animated: true); run(0.12)
        precondition(controller.isAnimatingLatest)
        move(1000); run(0.3)
        close(scroll.contentView.bounds.minY, 1000, "User scrolling cancels jump without later pullback")
        precondition(!controller.isAnimatingLatest && !controller.followingLatest && finishes == 1 && cancellations == 1)
        print("PASS wheel/live-scroll intent cancels motion and suppresses completion trimming")

        move(400); run(0.05)
        controller.followLatest(animated: true); run(0.12)
        grow(6800)
        window.setContentSize(NSSize(width: 340, height: 360))
        recordFrames(); controller.contentChanged()
        _ = sampleUntilDone()
        close(scroll.contentView.bounds.minY, maximum(), "Streaming growth and width/height reflow reach fresh actual end")
        precondition(finishes == 2)
        print("PASS animation retargets native lazy/document growth and viewport resize")

        reduced = true
        move(500); run(0.05)
        controller.followLatest(animated: true)
        precondition(!controller.isAnimatingLatest)
        run(0.16)
        close(scroll.contentView.bounds.minY, maximum(), "Reduced Motion uses original immediate behavior")
        precondition(finishes == 2)
        reduced = false
        print("PASS Reduced Motion keeps immediate positioning")

        move(1703); run(0.05)
        let anchor = controller.prepareForChange()!
        rowPrefix += 800; grow(7600)
        var nativeStart: CGFloat?
        controller.onFollowingChanged = { value in if value { nativeStart = scroll.contentView.bounds.minY } }
        proxyTargets.removeAll()
        controller.followLatest(animated: true, preserving: anchor)
        precondition(controller.isRestoringReadingPosition && controller.isAnimatingLatest)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        _ = sampleUntilDone()
        precondition(!proxyTargets.contains(anchor.id),
                     "A measured bridge anchor must not first proxy-scroll to its row top and flash before within-row restoration")
        close(nativeStart!, 2503, "Motion begins only after the reading anchor is restored")
        close(scroll.contentView.bounds.minY, maximum(), "Bridged latest end")
        precondition(finishes == 3)
        print("PASS old-page anchor restoration hands off to animation without a guessed delay")

        move(1500); run(0.05)
        let cancelledAnchor = controller.prepareForChange()!
        controller.followLatest(animated: true, preserving: cancelledAnchor)
        move(1800); run(0.3)
        close(scroll.contentView.bounds.minY, 1800, "User can cancel a pending bridge restoration")
        precondition(!controller.isAnimatingLatest && finishes == 3 && cancellations == 2)
        print("PASS pending bridge cancellation has no stale finish or delayed scroll")

        controller.followLatest(animated: true); run(0.1)
        let held = scroll.contentView.bounds.minY
        controller.cancelLatestJump()
        close(scroll.contentView.bounds.minY, held, "Explicit navigation cancellation keeps its native start")
        precondition(controller.prepareForChange() != nil && !controller.followingLatest)
        run(0.3)
        close(scroll.contentView.bounds.minY, held, "Explicit navigation cancellation has no delayed pullback")
        precondition(!controller.isAnimatingLatest && finishes == 3 && cancellations == 3)
        print("PASS public jump cancellation preserves the reading anchor and actual viewport for rebasing")
    }
}
private final class JumpDocument: NSView { override var isFlipped: Bool { true } }
