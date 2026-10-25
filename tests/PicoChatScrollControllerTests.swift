import AppKit
import SwiftUI

/// Uses native clip/document geometry in an unshown private window. It does not
/// activate an app, post pointer events, read user data, or run an agent.
@main struct PicoChatScrollControllerTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let controller = PicoChatScrollController()
        let document = FlippedChatDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 4000))
        let probe = PicoChatScrollProbeView(frame: NSRect(x: 0, y: 80, width: 400, height: 3920))
        probe.controller = controller; document.addSubview(probe)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.hasVerticalScroller = false; scroll.borderType = .noBorder
        scroll.autoresizingMask = [.width, .height]; scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.orderOut(nil) }
        var targets: [String] = []
        var edgeChanges: [(Bool, Bool)] = []
        controller.configure { id, _ in targets.append(id) }
        controller.onEdges = { edgeChanges.append(($0, $1)) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.24)) }
        func close(_ actual: CGFloat, _ expected: CGFloat, _ label: String) {
            precondition(abs(actual - expected) < 0.6, "\(label): \(actual), expected \(expected)")
        }
        func move(_ y: CGFloat, user: Bool = true) {
            if user { NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll) }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            if user {
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            }
        }
        func setHeight(_ height: CGFloat) {
            document.setFrameSize(NSSize(width: scroll.bounds.width, height: height))
            probe.setFrameSize(NSSize(width: scroll.bounds.width, height: height - 80))
        }
        var frames: [String: CGRect] = [:]
        for index in 0..<7 { frames["r\(index)"] = CGRect(x: 0, y: index * 500, width: 400, height: 500) }
        frames["picoLatest"] = CGRect(x: 0, y: 3500, width: 400, height: 420)
        func recordFrames() { for (id, frame) in frames { controller.record(id: id, frame: frame) } }
        recordFrames(); probe.attachSoon(); settle()
        close(scroll.contentView.bounds.minY, 3700, "Initial actual end")
        precondition(controller.followingLatest && edgeChanges.last?.0 == true && edgeChanges.last?.1 == false,
                     "onEdges order must be nearBottom, nearTop")
        print("PASS initial follow pins the actual native end and reports bottom/top callback order")

        move(703); settle()
        precondition(!controller.followingLatest, "Native user scroll intent must leave automatic following")
        let before = controller.prepareForChange()!
        precondition(before.id == "r1"); close(before.offset, 123, "Within-row reading offset")
        for (id, frame) in frames { frames[id] = frame.offsetBy(dx: 0, dy: 800) }
        setHeight(4800); recordFrames(); controller.restore(before)
        move(0, user: false)
        precondition(controller.prepareForChange() == before,
                     "A pending correction must keep its intended ID while lazy geometry temporarily shifts")
        settle()
        close(scroll.contentView.bounds.minY, 1503, "Reading anchor after older-page prepend")
        close(controller.prepareForChange()!.offset, 123, "Prepend retained within-row offset")
        precondition(controller.prepareForChange()!.id == "r1")
        print("PASS native user scroll and an 800pt prepend preserve the visible row and within-row offset")

        let beforeEviction = controller.prepareForChange()!
        for (id, frame) in frames { frames[id] = frame.offsetBy(dx: 0, dy: -500) }
        setHeight(4300); recordFrames(); controller.restore(beforeEviction); settle()
        close(scroll.contentView.bounds.minY, 1003, "Reading anchor after far-page eviction")
        let widthAnchor = controller.prepareForChange()!
        window.setContentSize(NSSize(width: 340, height: 300))
        for (id, frame) in frames {
            var next = frame; next.size.width = 340
            if id == "r1" { next.size.height += 200 }
            else if frame.minY > frames["r1"]!.minY { next.origin.y += 200 }
            frames[id] = next
        }
        setHeight(4500); recordFrames(); controller.restore(widthAnchor); settle()
        close(scroll.contentView.bounds.minY, 1003, "Width reflow retained reading anchor")
        precondition(controller.prepareForChange()!.id == "r1")
        print("PASS eviction and native viewport-width/text-height changes retain the reading anchor")

        controller.followLatest(); settle()
        close(scroll.contentView.bounds.minY, 4200, "Explicit latest after width reflow")
        setHeight(4700)
        var tail = frames["picoLatest"]!; tail.size.height += 200; frames["picoLatest"] = tail
        recordFrames(); controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 4400, "Streaming/tail height follows actual end")
        print("PASS explicit latest and later content-height growth keep the final content at the actual end")

        move(1003); settle()
        let historyAnchor = controller.prepareForChange()!
        controller.navigate(scope: "search:example")
        setHeight(600)
        controller.record(id: "s0", frame: CGRect(x: 0, y: 0, width: 340, height: 420))
        controller.record(id: "picoLatest", frame: CGRect(x: 0, y: 420, width: 340, height: 100))
        controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 0, "A new search starts at its top")
        move(140); settle()
        precondition(!controller.followingLatest)
        controller.navigate(scope: "history"); setHeight(4700); recordFrames(); controller.contentChanged(); settle()
        precondition(controller.prepareForChange()?.id == historyAnchor.id)
        close(controller.prepareForChange()!.offset, historyAnchor.offset, "History restored after search")
        controller.navigate(scope: "search:example"); setHeight(600)
        controller.record(id: "s0", frame: CGRect(x: 0, y: 0, width: 340, height: 420))
        controller.record(id: "picoLatest", frame: CGRect(x: 0, y: 420, width: 340, height: 100))
        controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 140, "Search retained its independent reading position")
        print("PASS normal history and search keep separate stable reading positions")

        var capturedAtTop: PicoChatScrollController.Anchor?
        var followingAtTop: Bool?
        controller.onUserEdge = { top, _ in
            if top {
                followingAtTop = controller.followingLatest
                capturedAtTop = controller.prepareForChange()
            }
        }
        controller.followLatest()
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        move(0)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        settle()
        close(scroll.contentView.bounds.minY, 0, "A real user-scroll notification cancels an outstanding latest correction")
        precondition(!controller.followingLatest)
        precondition(followingAtTop == false && capturedAtTop?.id == "s0",
                     "A top-edge pagination callback must see the new reading anchor before loading older messages")
        precondition(targets.contains("r1") && targets.contains("picoLatest"))
        print("PASS native live scrolling cancels outstanding corrections without fighting the user")

        controller.canFollowLatest = false
        move(300); settle()
        precondition(!controller.followingLatest && controller.prepareForChange()?.id == "s0",
                     "The bottom of a historical display page must not enable latest-reply following")
        controller.canFollowLatest = true
        move(250); settle(); move(300); settle()
        precondition(controller.followingLatest, "The actual conversation end can resume automatic following")
        print("PASS top-edge callbacks see a captured reading anchor; historical-page bottom does not enable following latest")

        controller.navigate(scope: "history")
        setHeight(4700); recordFrames(); controller.followLatest(); settle()
        precondition(controller.followingLatest)
        controller.navigate(scope: "search:from-latest")
        setHeight(600)
        controller.record(id: "latest-search", frame: CGRect(x: 0, y: 0, width: 340, height: 420))
        controller.record(id: "picoLatest", frame: CGRect(x: 0, y: 420, width: 340, height: 100))
        controller.contentChanged(); settle()
        precondition(!controller.followingLatest)
        controller.navigate(scope: "history")
        setHeight(4700); recordFrames(); controller.contentChanged(); settle()
        precondition(controller.followingLatest,
                     "Returning from search to latest-following history must restore following")
        close(scroll.contentView.bounds.minY, 4400, "Latest history restored at native end")
        print("PASS latest → search → history restores following the true native transcript end")

        move(1003); settle()
        let missingAnchor = controller.prepareForChange()!
        let missingFrame = frames[missingAnchor.id]!
        controller.remove(id: missingAnchor.id)
        var missingRequests = 0
        controller.configure { id, _ in
            guard id == missingAnchor.id else { return }
            missingRequests += 1
            // The first lazy ID lookup used old height estimates. Only its
            // second lookup realizes the requested row after reestimation.
            if missingRequests == 2 { controller.record(id: id, frame: missingFrame) }
        }
        controller.restore(missingAnchor); settle()
        precondition(missingRequests == 2 && controller.prepareForChange() == missingAnchor,
                     "An unrendered lazy target must get a bounded fresh ID lookup")
        close(scroll.contentView.bounds.minY, 1003, "Retried lazy ID lookup retained native offset")
        print("PASS lazy ID lookup retries an initially unrendered target, then settles without losing its anchor")
    }
}
private final class FlippedChatDocument: NSView { override var isFlipped: Bool { true } }
