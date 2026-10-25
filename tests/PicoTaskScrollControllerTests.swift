import AppKit
import SwiftUI

/// Native task-list positioning in an unshown private window. It never reads
/// application data, opens a provider connection, or posts global input.
@main struct PicoTaskScrollControllerTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let controller = PicoChatScrollController()
        controller.canFollowLatest = false
        let document = FlippedTaskListDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        let probe = PicoChatScrollProbeView(frame: document.bounds)
        probe.controller = controller; document.addSubview(probe)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.hasVerticalScroller = false; scroll.borderType = .noBorder; scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.orderOut(nil) }
        var frames: [String: CGRect] = [:]
        var targetRequests: [String] = []
        controller.configure { id, _ in targetRequests.append(id) }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.28)) }
        func close(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
            precondition(abs(actual - expected) < 0.6, "\(message): actual\(actual), expected\(expected)")
        }
        func move(_ y: CGFloat) {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            settle()
        }
        func populate(_ prefix: String, height: CGFloat = 2000) {
            frames = ["taskChrome": CGRect(x: 0, y: 0, width: 400, height: 240)]
            for index in 0..<20 {
                frames["\(prefix)\(index)"] = CGRect(x: 0, y: 240 + index * 66, width: 400, height: 66)
            }
            document.setFrameSize(NSSize(width: 400, height: height)); probe.setFrameSize(document.bounds.size)
            for (id, frame) in frames { controller.record(id: id, frame: frame) }
            controller.contentChanged()
        }

        controller.navigate(scope: "tasks:todo")
        populate("todo"); probe.attachSoon(); settle()
        close(scroll.contentView.bounds.minY, 0, "A new task scope starts at top")
        move(579)
        precondition(controller.prepareForChange()?.id == "todo5")
        controller.scrollToTop(); settle()
        close(scroll.contentView.bounds.minY, 0, "Explicit top cancels old reading intention")
        controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 0, "Later geometry cannot return to the old task")
        precondition(!controller.followingLatest)
        print("PASS task scopes start at top; explicit return-to-top remains top without tail following")

        move(70)
        controller.navigate(scope: "tasks:completed", preservingSharedHeaderID: "taskChrome")
        populate("completed", height: 1800); settle()
        close(scroll.contentView.bounds.minY, 70, "Todo→Completed preserves the shared header and input position")
        precondition(controller.prepareForChange()?.id == "taskChrome")
        move(645)
        let completedAnchor = controller.prepareForChange()!
        precondition(completedAnchor.id == "completed6")
        controller.navigate(scope: "tasks:todo")
        populate("todo"); settle()
        close(scroll.contentView.bounds.minY, 70, "Todo retains its own saved position")
        controller.navigate(scope: "tasks:completed")
        populate("completed", height: 1800); settle()
        precondition(controller.prepareForChange() == completedAnchor)
        close(scroll.contentView.bounds.minY, 645, "Completed retains its own reading task")
        print("PASS shared chrome does not move on visible-header tab switches; deeper scopes retain independent task anchors")

        move(100)
        let unchangedHeader = frames["taskChrome"]!
        let retainedHeaderIDs: Set<String> = ["taskChrome"]
        let headerProxyCount = targetRequests.filter { $0 == "taskChrome" }.count
        controller.navigate(scope: "tasks:shared-header-no-layout",
                            preservingSharedHeaderID: "taskChrome", retainingGeometryIDs: retainedHeaderIDs)
        // Mirror real SwiftUI: only task rows were replaced. The common header
        // remained mounted at the identical frame and emits no new measurement.
        frames = ["taskChrome": unchangedHeader,
                  "unchanged-scope-task": CGRect(x: 0, y: 240, width: 400, height: 66)]
        controller.record(id: "unchanged-scope-task", frame: frames["unchanged-scope-task"]!)
        controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 100, "An unchanged shared header need not re-register after a tab switch")
        precondition(targetRequests.filter { $0 == "taskChrome" }.count == headerProxyCount,
                     "A measured common header must remain in place without a proxy jump to zero")
        precondition(controller.prepareForChange()?.id == "taskChrome")
        close(controller.prepareForChange()!.offset, 100, "Unchanged shared header retains its visual offset")
        controller.navigate(scope: "tasks:search:header-query", retainingGeometryIDs: retainedHeaderIDs)
        controller.record(id: "query-task", frame: CGRect(x: 0, y: 240, width: 400, height: 66))
        controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 0, "A new query starts at top without inheriting header position")
        move(140)
        controller.navigate(scope: "tasks:shared-header-no-layout", retainingGeometryIDs: retainedHeaderIDs)
        controller.record(id: "unchanged-scope-task", frame: frames["unchanged-scope-task"]!)
        controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 100, "Clearing query restores the prior100pt header without a geometry event")
        controller.navigate(scope: "tasks:search:header-query", retainingGeometryIDs: retainedHeaderIDs)
        controller.record(id: "query-task", frame: CGRect(x: 0, y: 240, width: 400, height: 66))
        controller.contentChanged(); settle()
        close(scroll.contentView.bounds.minY, 140, "The query independently retains its own header offset")
        print("PASS unchanged chrome geometry survives filter/query scopes without new layout callbacks; query/header positions remain independent")

        controller.navigate(scope: "tasks:todo"); populate("todo"); settle()
        move(384) // todo2 +12pt; todo3 starts 54pt beneath the viewport top.
        let removed = controller.prepareForChange()!
        precondition(removed.id == "todo2"); close(removed.offset, 12, "Removed task's within-row offset")
        let survivors = Set(frames.keys.filter { $0 != removed.id })
        let neighbour = controller.prepareForChange(survivingIDs: survivors)!
        precondition(neighbour.id == "todo3")
        close(neighbour.offset, -54, "Neighbour keeps its actual on-screen y")
        controller.remove(id: removed.id); frames.removeValue(forKey: removed.id)
        for (id, frame) in frames where frame.minY > 372 { frames[id] = frame.offsetBy(dx: 0, dy: -66) }
        document.setFrameSize(NSSize(width: 400, height: 1934)); probe.setFrameSize(document.bounds.size)
        for (id, frame) in frames { controller.record(id: id, frame: frame) }
        controller.restore(neighbour); settle()
        close(scroll.contentView.bounds.minY, 318, "Completing the anchored task keeps its neighbour fixed")
        close(frames[neighbour.id]!.minY - scroll.contentView.bounds.minY, 54, "Neighbour visual offset after completion")
        precondition(!targetRequests.contains(removed.id), "A removed task must never be requested again")
        print("PASS completing/reopening an anchored task selects a surviving visible neighbour at its prior visual position")

        // A still-present task keeps its stable ID rather than switching to a
        // neighbouring row merely because other tasks were added or removed.
        let retained = controller.prepareForChange()!
        let retainedResult = controller.prepareForChange(survivingIDs: Set(frames.keys))
        precondition(retainedResult == retained)
        for id in frames.keys where id != "taskChrome" { controller.remove(id: id) }
        let unavailable = controller.prepareForChange(survivingIDs: ["taskChrome"])
        precondition(unavailable == nil, "An offscreen header is not a visible neighbour fallback")
        controller.scrollToTop(); settle()
        close(scroll.contentView.bounds.minY, 0, "No visible survivor can explicitly fall back to top")
        print("PASS surviving current IDs are retained; no visible survivor returns nil for an explicit top fallback")

        controller.navigate(scope: "tasks:live-paging")
        populate("live"); settle()
        move(519)
        let beforeLivePage = controller.prepareForChange()!
        precondition(beforeLivePage.id == "live4")
        close(beforeLivePage.offset, 15, "Live page's original intra-row offset")
        for shift in [CGFloat(528), CGFloat(-528)] {
            let expected = scroll.contentView.bounds.minY + shift
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            let pending = controller.prepareForChange()!
            let liveOffset = scroll.contentView.bounds.minY
            for (id, frame) in frames where id != "taskChrome" { frames[id] = frame.offsetBy(dx: 0, dy: shift) }
            let height = document.bounds.height + shift
            document.setFrameSize(NSSize(width: 400, height: height)); probe.setFrameSize(document.bounds.size)
            for (id, frame) in frames { controller.record(id: id, frame: frame) }
            controller.restore(pending)
            precondition(controller.isRestoringReadingPosition && controller.prepareForChange() == pending,
                         "A live gesture must retain an explicit pagination anchor")
            settle()
            close(scroll.contentView.bounds.minY, liveOffset, "Pending pagination does not fight an active native gesture")
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
            precondition(controller.prepareForChange() == pending, "Lazy page geometry must not replace the pending visual anchor")
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
            settle()
            close(scroll.contentView.bounds.minY, expected, "Live pagination restores the original task after native scroll ends")
            precondition(controller.prepareForChange() == beforeLivePage && !controller.isRestoringReadingPosition,
                         "The stable task ID and intra-row offset must survive both prepend and far-page eviction")
        }
        print("PASS live-scroll prepend/eviction retains the explicit task ID+offset and restores it only after native scrolling ends")

        controller.retainedScopes = ["todo", "completed"]
        controller.navigate(scope: "todo"); populate("retainedTodo"); settle()
        move(579)
        let retainedTodo = controller.prepareForChange()!
        precondition(retainedTodo.id == "retainedTodo5")
        controller.navigate(scope: "completed"); populate("retainedCompleted"); settle()
        move(645)
        let retainedCompleted = controller.prepareForChange()!
        precondition(retainedCompleted.id == "retainedCompleted6")
        for index in 0..<25 {
            controller.navigate(scope: "todo:query:prefix\(index)")
            populate("query\(index)")
            let cached = Mirror(reflecting: controller).children.first { $0.label == "positions" }!.value
            precondition(Mirror(reflecting: cached).children.count <= 12,
                         "Typed search prefixes must not grow the native position cache")
        }
        settle()
        controller.navigate(scope: "todo"); populate("retainedTodo"); settle()
        precondition(controller.prepareForChange() == retainedTodo,
                     "More than12typed-query scopes must not evict the Todo bookmark")
        close(scroll.contentView.bounds.minY, 579, "Todo retains its deep native offset after25queries")
        controller.navigate(scope: "completed"); populate("retainedCompleted"); settle()
        precondition(controller.prepareForChange() == retainedCompleted,
                     "Completed retains a separate bookmark while query scopes are evicted")
        close(scroll.contentView.bounds.minY, 645, "Completed retains its independent deep native offset after25queries")
        print("PASS25typed-query scopes keep the cache<=12while retaining distinct Todo andCompleted reading bookmarks")
    }
}

private final class FlippedTaskListDocument: NSView { override var isFlipped: Bool { true } }
