import Foundation

@main struct ZoomMeetingExitDriverTests {
    static func main() async throws {
        try await run()
        print("PASS: bound Zoom exit, explicit modes, host handoff refusal, one-shot mutations, read-back evidence, cancellation and new-meeting isolation")
    }
    static func run() async throws {
        typealias Driver = ZoomMeetingExitDriver
        let leave = FakeMeetingExitAX()
        let driver = Driver(transport: leave, timeout: 1, pollInterval: 1_000_000)
        let bound = try await driver.bindCurrentMeeting()
        precondition(bound.pid == 42 && bound.meetingID == "meeting-one" && bound.meetingInfoFingerprint != nil)
        precondition(leave.actions.isEmpty, "binding must be read-only")
        let outcome = try await driver.exit()
        precondition(outcome.confirmed && outcome.mode == .leave && outcome.pid == 42)
        precondition(leave.confirmedReads >= 2 && leave.actions == [.press("main-end"), .press("leave")], "never claim exit before the main window actually disappears")

        let end = FakeMeetingExitAX()
        let endDriver = Driver(transport: end, timeout: 1, pollInterval: 1_000_000)
        _ = try await endDriver.bindCurrentMeeting()
        let ended = try await endDriver.exit(mode: .endForAll)
        precondition(ended.confirmed && ended.mode == .endForAll && end.actions == [.press("main-end"), .press("end-all")])

        let disappeared = FakeMeetingExitAX()
        let absentDriver = Driver(transport: disappeared, timeout: 1, pollInterval: 1_000_000)
        _ = try await absentDriver.bindCurrentMeeting(); disappeared.mainVisible = false
        try await expect(.changedMeeting) { _ = try await absentDriver.exit() }
        precondition(disappeared.actions.isEmpty, "main window absence without a dispatched confirmation is not a successful exit")

        let foreignDialog = FakeMeetingExitAX(); foreignDialog.dialogVisible = true
        let foreign = Driver(transport: foreignDialog, timeout: 1, pollInterval: 1_000_000)
        _ = try await foreign.bindCurrentMeeting()
        try await expect(.unrelatedDialog) { _ = try await foreign.exit() }
        precondition(foreignDialog.actions.isEmpty, "do not confirm another interaction's existing exit dialog")

        let changed = FakeMeetingExitAX()
        let changedDriver = Driver(transport: changed, timeout: 1, pollInterval: 1_000_000)
        _ = try await changedDriver.bindCurrentMeeting(); changed.meetingID = "meeting-two"
        try await expect(.changedMeeting) { _ = try await changedDriver.exit(mode: .endForAll) }
        precondition(changed.actions.isEmpty, "same PID/window must not authorize a different meeting ID")

        let anotherWindow = FakeMeetingExitAX()
        let windowDriver = Driver(transport: anotherWindow, timeout: 1, pollInterval: 1_000_000)
        _ = try await windowDriver.bindCurrentMeeting(); anotherWindow.windowID = "new-main-window"
        try await expect(.changedMeeting) { _ = try await windowDriver.exit() }
        precondition(anotherWindow.actions.isEmpty)

        let changedBetween = FakeMeetingExitAX(); changedBetween.changeMeetingAfterOpening = true
        let guarded = Driver(transport: changedBetween, timeout: 1, pollInterval: 1_000_000)
        _ = try await guarded.bindCurrentMeeting()
        try await expect(.changedMeeting) { _ = try await guarded.exit() }
        precondition(changedBetween.actions == [.press("main-end")], "recheck identity before the destructive confirmation")

        let host = FakeMeetingExitAX(); host.requiresHostTransfer = true
        let hostDriver = Driver(transport: host, timeout: 1, pollInterval: 1_000_000)
        _ = try await hostDriver.bindCurrentMeeting()
        try await expect(.handoffRequired) { _ = try await hostDriver.exit() }
        precondition(host.actions == [.press("main-end"), .press("leave")], "never assign a new host or click a transfer control")

        let unavailable = FakeMeetingExitAX(); unavailable.canEndForAll = false
        let unavailableDriver = Driver(transport: unavailable, timeout: 1, pollInterval: 1_000_000)
        _ = try await unavailableDriver.bindCurrentMeeting()
        try await expect(.endForAllUnavailable) { _ = try await unavailableDriver.exit(mode: .endForAll) }
        precondition(unavailable.actions == [.press("main-end")], "endForAll must never silently fall back to leave")

        let stalled = FakeMeetingExitAX(); stalled.keepMeetingAfterConfirmation = true
        let bounded = Driver(transport: stalled, timeout: 0.04, pollInterval: 1_000_000)
        _ = try await bounded.bindCurrentMeeting()
        try await expect(.timedOut) { _ = try await bounded.exit() }
        try await expect(.timedOut) { _ = try await bounded.exit() }
        precondition(stalled.actions == [.press("main-end"), .press("leave")], "an uncertain confirmation may only be read back, never dispatched again")

        let cancelled = FakeMeetingExitAX()
        let cancellable = Driver(transport: cancelled, timeout: 1, pollInterval: 1_000_000)
        _ = try await cancellable.bindCurrentMeeting()
        cancelled.onAction = { action in if action == .press("main-end") { cancellable.cancel() } }
        try await expect(.cancelled) { _ = try await cancellable.exit() }
        precondition(cancelled.actions == [.press("main-end")])
        cancelled.onAction = nil
        let resumed = try await cancellable.exit()
        precondition(resumed.confirmed && cancelled.actions == [.press("main-end"), .press("leave")], "cancel preserves the original identity and owned dialog for a later explicit exit")

        let cancelledConfirmation = FakeMeetingExitAX(); cancelledConfirmation.keepMeetingAfterConfirmation = true
        let uncertain = Driver(transport: cancelledConfirmation, timeout: 1, pollInterval: 1_000_000)
        _ = try await uncertain.bindCurrentMeeting()
        cancelledConfirmation.onAction = { action in if action == .press("leave") { uncertain.cancel() } }
        try await expect(.cancelled) { _ = try await uncertain.exit() }
        cancelledConfirmation.onAction = nil
        try await expect(.unconfirmedAction) { _ = try await uncertain.exit() }
        precondition(cancelledConfirmation.actions == [.press("main-end"), .press("leave")], "post-dispatch cancellation must never allow a second destructive confirmation")

        cancelled.mainVisible = true; cancelled.dialogVisible = false; cancelled.confirmationPending = false
        cancelled.meetingID = "meeting-new-start"; cancelled.info = "Synthetic second dedicated meeting"
        cancellable.cancel()
        let rebound = try await cancellable.bindCurrentMeeting()
        precondition(rebound.id != bound.id && rebound.meetingID == "meeting-new-start")
        let later = try await cancellable.exit()
        precondition(later.confirmed, "explicit owner rebind resets cancellation and permits a new session")

        let noIdentity = FakeMeetingExitAX(); noIdentity.includeIdentity = false
        let noIdentityDriver = Driver(transport: noIdentity, timeout: 1)
        try await expect(.identityUnavailable) { _ = try await noIdentityDriver.bindCurrentMeeting() }
        try await expect(.notBound) { _ = try await noIdentityDriver.exit() }
        precondition(noIdentity.actions.isEmpty)
    }
    private static func expect(_ expected: ZoomMeetingExitDriver.Failure, _ operation: () async throws -> Void) async throws {
        do { try await operation(); preconditionFailure("expected \(expected)") }
        catch let actual as ZoomMeetingExitDriver.Failure { precondition(actual == expected, "\(actual) != \(expected)") }
    }
}

/// In-memory AX fixtures only. No public AX function, input event, model, meeting
/// or application is read/operated by this executable.
private final class FakeMeetingExitAX: ZoomSlidesAXTransport, @unchecked Sendable {
    var actions: [ZoomSlidesAXAction] = []
    var mainVisible = true, dialogVisible = false, confirmationPending = false
    var requiresHostTransfer = false, canEndForAll = true, keepMeetingAfterConfirmation = false
    var changeMeetingAfterOpening = false, includeIdentity = true
    var meetingID = "meeting-one", windowID = "bound-main-window", info = "Synthetic dedicated meeting"
    var confirmedReads = 0
    var onAction: ((ZoomSlidesAXAction) -> Void)?
    func read(pid: pid_t?, deadline: Date, cancelled: () throws -> Void) throws -> ZoomSlidesAXState {
        try cancelled()
        if confirmationPending {
            confirmedReads += 1
            if confirmedReads >= 2 && !requiresHostTransfer && !keepMeetingAfterConfirmation { mainVisible = false; dialogVisible = false }
        }
        var windows: [ZoomSlidesAXWindow] = []
        if mainVisible {
            var main = ZoomSlidesAXWindow(id: windowID, title: "Zoom Meeting", nodes: [
                .init(id: "main", role: "AXWindow", identifier: "zm.meeting.window.main"),
                .init(id: "main-end", role: "AXButton", description: "End", identifier: "leave"),
                .init(id: "mic", role: "AXButton", description: "Unmute my audio"),
                .init(id: "participants", role: "AXButton", description: "Open participants panel, closed, 2 participants")])
            if includeIdentity {
                main.nodes += [.init(id: "info", role: "AXButton", description: info, identifier: "MeetingTopBarInfoButton"),
                               .init(id: "web", role: "AXWebArea", url: "https://dg01slides.zoom.us/p/synthetic-deck/60000?mainMeetingID=\(meetingID)")]
            }
            windows.append(main)
        }
        if dialogVisible {
            var nodes: [ZoomSlidesAXNode] = [.init(id: "dialog", role: "AXWindow", identifier: "zm.meeting.window.leave"),
                .init(id: "cancel", role: "AXButton", description: "Cancel", identifier: "zm.meeting.leavemeeting.cancelButton")]
            if confirmationPending && requiresHostTransfer { nodes.append(.init(id: "assign-host", role: "AXButton", description: "Assign a new host and leave")) }
            else {
                nodes.append(.init(id: "leave", role: "AXButton", description: "Leave meeting", identifier: "zm.meeting.leavemeeting.leaveMeetingButton"))
                if canEndForAll { nodes.append(.init(id: "end-all", role: "AXButton", description: "End meeting for all", identifier: "zm.meeting.leavemeeting.endMeetingButton")) }
            }
            windows.append(.init(id: "exit-dialog", title: "", nodes: nodes))
        }
        return .init(pid: 42, windows: windows)
    }
    func perform(_ action: ZoomSlidesAXAction, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws {
        try cancelled(); precondition(pid == 42); actions.append(action)
        switch action {
        case .press("main-end"):
            dialogVisible = true
            if changeMeetingAfterOpening { meetingID = "meeting-replaced" }
        case .press("leave"), .press("end-all"): confirmationPending = true
        default: preconditionFailure("unexpected exit action: \(action)")
        }
        onAction?(action)
        try cancelled() // The native transport may detect cancellation after dispatch.
    }
}
