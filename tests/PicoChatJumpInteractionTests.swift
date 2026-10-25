import AppKit
import SwiftUI

/// Exercise the production Chat button against private, persisted history.
/// Every gesture is delivered only to this window; no model or global mouse.
@main struct PicoChatJumpInteractionTests {
    @MainActor static func main() throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let originalEnvironment = ProcessInfo.processInfo.environment
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pico-jump-interaction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        unsetenv("TELOS_PREVIEW"); setenv("TELOS_DATA_DIR", directory.path, 1)
        defer {
            try? FileManager.default.removeItem(at: directory)
            for key in ["TELOS_PREVIEW", "TELOS_DATA_DIR"] {
                if let value = originalEnvironment[key] { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        for (scenario, count, hugeTail) in [("same-page", 50, false), ("huge-tail", 360, true), ("cross-page", 360, false)] {
            if let filter = ProcessInfo.processInfo.environment["PICO_JUMP_SCENARIO"],
               filter == "normal" ? hugeTail : filter != scenario { continue }
            let data = directory.appendingPathComponent("history-\(scenario)")
            let huge = hugeTail ? String(repeating: "中文 mixed English long paragraph for lazy layout.\n", count: 2300) : ""
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let messages = (0..<count).map { index in
                Message(role: index.isMultiple(of: 2) ? "user" : "assistant",
                    text: hugeTail && index >= count - 80 ? "MESSAGE \(index) BEGIN\n" + huge + "\nMESSAGE \(index) END" : "Message \(index). A private test paragraph with enough natural English and 中文 to wrap across several lines at the small window width. Keep this message attached to its original conversation position.")
            }
            struct Snapshot: Encodable {
                let conversationID: UUID
                let messages: [Message]
                let artifacts: [Artifact] = []
                let status = "idle"
            }
            let bytes = try JSONEncoder().encode(Snapshot(conversationID: UUID(), messages: messages))
            let file = data.appendingPathComponent("chat.json")
            try bytes.write(to: file)
            let chat = PicoChatStore(dataDir: data)
            let expectedTail = PicoChatTimelineRows.build(messages: Array(messages.suffix(80)))
            if hugeTail {
                precondition(expectedTail.count > 3000, "The final page must contain thousands of chunks")
                for _ in 0..<3 { chat.loadEarlier() }
                precondition(chat.hasLaterMessages)
            }
            let host = FirstMouseHostingView(rootView: JumpFixture(chat: chat))
            host.sizingOptions = []; host.safeAreaRegions = []
            let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 374, height: 528),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host; window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua); window.orderBack(nil)
            defer { window.orderOut(nil) }
            func settle(_ seconds: Double = 0.6) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            func scroll() -> NSScrollView {
                descendants(host).compactMap { $0 as? NSScrollView }.first { $0.contentView.bounds.height > 200 }!
            }
            func controller() -> PicoChatScrollController {
                descendants(host).compactMap { ($0 as? PicoChatScrollProbeView)?.controller }.first!
            }
            func offset() -> CGFloat {
                let s = scroll(), clip = s.contentView.bounds, doc = s.documentView!
                return doc.isFlipped ? clip.minY : doc.bounds.maxY - clip.maxY
            }
            func maximum() -> CGFloat {
                max(0, scroll().documentView!.bounds.height - scroll().contentView.bounds.height)
            }
            func latestTarget() -> CGFloat {
                let measured = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
                guard let tail = measured["picoLatest"] else { return maximum() }
                let s = scroll(), document = s.documentView!
                let probe = descendants(host).compactMap { $0 as? PicoChatScrollProbeView }.first!
                let frame = probe.convert(probe.bounds, to: document)
                let origin = document.isFlipped ? frame.minY : document.bounds.maxY - frame.maxY
                return min(maximum(), max(0, origin + tail.maxY - s.contentView.bounds.height))
            }
            func anchorViewportY(_ anchor: PicoChatScrollController.Anchor) -> CGFloat? {
                let measured = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
                guard let row = measured[anchor.id] else { return nil }
                let s = scroll(), document = s.documentView!
                let probe = descendants(host).compactMap { $0 as? PicoChatScrollProbeView }.first!
                let frame = probe.convert(probe.bounds, to: document)
                let origin = document.isFlipped ? frame.minY : document.bounds.maxY - frame.maxY
                return origin + row.minY - offset()
            }
            func userScroll(_ y: CGFloat, settleAfter: Double = 0.6) {
                let s = scroll(), doc = s.documentView!
                NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: s)
                let nativeY = doc.isFlipped ? y : doc.bounds.maxY - s.contentView.bounds.height - y
                s.contentView.scroll(to: NSPoint(x: 0, y: nativeY)); s.reflectScrolledClipView(s.contentView)
                NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: s)
                NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: s)
                settle(settleAfter)
            }
            func nodes(_ root: Any) -> [NSObject] {
                guard let value = root as? NSObject else { return [] }
                let children = (value as? any NSAccessibilityProtocol)?.accessibilityChildren()
                    ?? (value.accessibilityAttributeValue(.children) as? [Any]) ?? []
                return [value] + children.flatMap(nodes)
            }
            func label(_ value: NSObject) -> String {
                let selector = NSSelectorFromString("accessibilityLabel")
                if value.responds(to: selector), let result = value.perform(selector)?.takeUnretainedValue() as? String { return result }
                return value.accessibilityAttributeValue(.description) as? String ?? ""
            }
            func press(_ name: String) {
                guard let button = nodes(host).first(where: { label($0) == name }) else { fatalError("Missing production control \(name)") }
                let selector = NSSelectorFromString("accessibilityPerformPress")
                typealias Press = @convention(c) (AnyObject, Selector) -> Bool
                precondition(button.responds(to: selector))
                precondition(unsafeBitCast(button.method(for: selector), to: Press.self)(button, selector))
            }
            settle(1)
            precondition(maximum() > 500, "The test must have a real scrolling viewport")
            if count > 80 && !hugeTail {
                // Enter an older bounded store page without starting any run.
                userScroll(maximum() * 0.45)
                for _ in 0..<3 {
                    chat.loadEarlier()
                    settle()
                }
                precondition(chat.hasLaterMessages, "The cross-page fixture must not already contain the latest store page")
            }
            userScroll(maximum() * 0.45)
            precondition(!controller().followingLatest)
            let initial = offset()
            let oldAnchor = controller().prepareForChange()!
            let oldAnchorY = anchorViewportY(oldAnchor)!
            press("Jump to latest message")
            var samples: [CGFloat] = [initial]
            settle(1.0 / 120)
            let handoffAnchorY = anchorViewportY(oldAnchor)
            print("HANDOFF \(scenario): old anchor y=\(oldAnchorY), after first frame=\(String(describing: handoffAnchorY))")
            for _ in 0..<150 {
                settle(1.0 / 60)
                samples.append(offset())
                precondition(offset() >= -1 && offset() <= maximum() + 2, "Native jump may not overscroll outside its current document")
                precondition(chat.messages.count <= 240 && !chat.isRunning)
                let active = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
                precondition(active.count <= 321, "A transient old/latest bridge must remain bounded during every native frame")
            }
            let final = offset()
            let intermediates = Set(samples.filter { abs($0 - initial) > 2 && abs($0 - final) > 2 }.map { Int($0.rounded()) })
            let distance = abs(final - initial)
            let middleFrames = samples.filter {
                let progress = abs($0 - initial) / max(1, distance)
                return progress > 0.2 && progress < 0.8
            }.count
            print("JUMP \(scenario): initial=\(initial), first=\(samples[1]), final=\(final), maximum=\(maximum()), intermediate positions=\(intermediates.count), middleFrames=\(middleFrames)")
            precondition(intermediates.count >= 8, "Clicking the production Jump button must visibly scroll through multiple positions, rather than teleport")
            if count <= 80 {
                precondition(abs(samples[1] - initial) < distance * 0.25,
                             "The first native frame must not teleport most of the distance before animating a tiny final correction")
                precondition(middleFrames >= 4,
                             "The actual traversal must have several middle frames, not just lazy-layout jitter at its endpoint")
            } else {
                precondition(handoffAnchorY != nil && abs(handoffAnchorY! - oldAnchorY) < 10,
                             "Replacing a bounded historical page must preserve the visible old row during handoff, rather than flash a different page before scrolling")
            }
            precondition(controller().followingLatest && !chat.hasLaterMessages && abs(final - latestTarget()) < 2,
                         "The real button must finish at the true latest end")
            let tracked = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
            precondition(tracked.count <= 321, "Explicit latest navigation must keep row realization bounded")
            precondition(tracked[expectedTail.last!.id] != nil,
                         "Finishing at a bounded page footer must also display the actual final message chunk")
            let tailScreenY = anchorViewportY(.init(id: expectedTail.last!.id, offset: 0))! + tracked[expectedTail.last!.id]!.height
            let footerScreenBottom = anchorViewportY(.init(id: "picoLatest", offset: 0))! + tracked["picoLatest"]!.height
            print("GEOMETRY \(scenario): finalChunkBottom=\(tailScreenY), footerBottom=\(footerScreenBottom), viewportHeight=\(scroll().contentView.bounds.height), logicalEnd=\(latestTarget()), nativeMaximum=\(maximum())")
            precondition(tailScreenY > 0 && tailScreenY <= scroll().contentView.bounds.height,
                         "The true final message chunk must be physically visible")
            precondition(abs(footerScreenBottom - scroll().contentView.bounds.height) < 2,
                         "The actual latest footer must align with the viewport bottom")
            print("PASS production Chat Jump \(scenario): native animated positions, true end, bounded history")
            if count > 80 && !hugeTail {
                // Start a second far jump, then interrupt it with this window's
                // own native scrolling. The retained bridge must remain usable.
                userScroll(maximum() * 0.45)
                for _ in 0..<3 { chat.loadEarlier(); settle() }
                userScroll(maximum() * 0.45)
                let motionStart = offset()
                let ownerIndices = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.id.uuidString, $0) })
                func historicalOwnerVisible() -> Bool {
                    let frames = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
                    let s = scroll(), document = s.documentView!
                    let probe = descendants(host).compactMap { $0 as? PicoChatScrollProbeView }.first!
                    let rect = probe.convert(probe.bounds, to: document)
                    let origin = document.isFlipped ? rect.minY : document.bounds.maxY - rect.maxY
                    let top = offset() - origin
                    return frames.contains { id, frame in
                        guard let owner = ownerIndices[String(id.prefix(36))] else { return false }
                        return owner < count - 80 && frame.maxY > top + 0.5 && frame.minY < top + s.contentView.bounds.height
                    }
                }
                press("Jump to latest message")
                // Different renderers can realize the bridge at different speeds.
                // Interrupt actual motion while its historical half is visible,
                // rather than assume a fixed delay still points at an older page.
                let cancellationDeadline = Date().addingTimeInterval(1)
                var readyToCancel = false
                repeat {
                    settle(1.0 / 240)
                    readyToCancel = controller().isAnimatingLatest && abs(offset() - motionStart) > 2 && historicalOwnerVisible()
                } while !readyToCancel && controller().isAnimatingLatest && Date() < cancellationDeadline
                precondition(readyToCancel, "The cancellation fixture must interrupt real motion over a visible historical owner")
                userScroll(max(0, offset() - 160), settleAfter: 0.03)
                let cancelled = controller().prepareForChange()!
                let cancelledOwner = ownerIndices[String(cancelled.id.prefix(36))]!
                precondition(cancelledOwner < count - 80, "Search restoration must start from a historical owner outside the latest page")
                print("CANCEL historical owner=\(cancelledOwner), latest page begins=\(count - 80)")
                let cancelledY = anchorViewportY(cancelled)
                settle(0.5)
                precondition(!controller().isAnimatingLatest && !controller().followingLatest,
                             "User scrolling must cancel the explicit latest motion")
                precondition(cancelledY != nil && anchorViewportY(cancelled) != nil &&
                             abs(anchorViewportY(cancelled)! - cancelledY!) < 12,
                             "Cancelling must keep the rows currently being read")
                print("PASS cancelled far jump: visible row remains in place")
                host.rootView = JumpFixture(chat: chat, query: "Message 17.")
                settle()
                precondition(!controller().isAnimatingLatest && chat.messages.count <= 240)
                host.rootView = JumpFixture(chat: chat)
                settle()
                precondition(!controller().isAnimatingLatest && chat.hasLaterMessages,
                             "Search must normalize an interrupted bridge back to its actual reading page")
                print("PASS search directly after cancelled bridge: returns to historical page")
                // Resume normal paging from the retained history. AX invokes
                // the actual production button without any global pointer.
                let firstBeforePaging = messages.firstIndex { $0.id == chat.messages.first!.id }!
                userScroll(0)
                if nodes(host).contains(where: { label($0) == "Earlier messages" }) {
                    press("Earlier messages"); settle()
                }
                let firstAfterPaging = messages.firstIndex { $0.id == chat.messages.first!.id }!
                precondition(firstAfterPaging <= firstBeforePaging,
                             "Normal native edge pagination must not move the historical page forward")
                precondition(!chat.messages.contains(where: { $0.id == messages.last!.id }),
                             "Earlier navigation after cancellation must resume the historical page, not evict it for latest")
                precondition(chat.messages.count <= 240 && !controller().isAnimatingLatest)
                print("PASS earlier paging after cancelled bridge: bounded historical page starts at message \(firstBeforePaging) -> \(firstAfterPaging)")
                // Search and return preserve the same Chat view identity; this
                // exercises scope cleanup after the interrupted latest jump.
                host.rootView = JumpFixture(chat: chat, query: "Message 17.")
                settle()
                precondition(!controller().isAnimatingLatest)
                host.rootView = JumpFixture(chat: chat)
                settle()
                userScroll(maximum() * 0.45)
                print("REPEAT before click: \(controller().diagnosticSnapshot), storeLater=\(chat.hasLaterMessages)")
                press("Jump to latest message")
                var elapsed: Double = 0
                for checkpoint in [0.5, 1.0, 2.6, 4.0] {
                    settle(checkpoint - elapsed); elapsed = checkpoint
                    let frames = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
                    print("REPEAT after \(checkpoint)s: \(controller().diagnosticSnapshot), animating=\(controller().isAnimatingLatest), storeLater=\(chat.hasLaterMessages), logicalEnd=\(latestTarget()), nativeEnd=\(maximum()), actualTailPresent=\(frames[expectedTail.last!.id] != nil)")
                }
                let repeatedFrames = Mirror(reflecting: controller()).children.first { $0.label == "rows" }!.value as! [String: CGRect]
                precondition(controller().followingLatest && !chat.hasLaterMessages &&
                             repeatedFrames["picoLatest"] != nil && repeatedFrames[expectedTail.last!.id] != nil &&
                             abs(offset() - latestTarget()) < 2,
                             "A cancelled jump followed by paging and search must still reach true latest on the next button click")
                let repeatedFooterBottom = anchorViewportY(.init(id: "picoLatest", offset: 0))! + repeatedFrames["picoLatest"]!.height
                let repeatedChunkBottom = anchorViewportY(.init(id: expectedTail.last!.id, offset: 0))! + repeatedFrames[expectedTail.last!.id]!.height
                precondition(abs(repeatedFooterBottom - scroll().contentView.bounds.height) < 2 &&
                             repeatedChunkBottom > 0 && repeatedChunkBottom <= scroll().contentView.bounds.height)
                print("PASS search after cancelled bridge and repeat jump to true latest: finalChunkBottom=\(repeatedChunkBottom), footerBottom=\(repeatedFooterBottom), viewport=\(scroll().contentView.bounds.height)")
            }
            let persisted = try Data(contentsOf: file)
            precondition(persisted == bytes, "Scrolling must preserve persisted messages")
            print("PASS \(scenario): unchanged persisted messages and no worker run")
            window.orderOut(nil)
        }
    }
}

private struct JumpFixture: View {
    @ObservedObject var chat: PicoChatStore
    var query = ""
    var body: some View {
        PicoChatView(chat: chat, query: query, headerInset: 60)
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black).environment(\.colorScheme, .dark).foregroundStyle(.white)
    }
}
