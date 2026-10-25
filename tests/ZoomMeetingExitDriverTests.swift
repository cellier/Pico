import Foundation

@main struct ZoomMeetingExitDriverTests {
    static func main() async throws {
        try await run()
        print("PASS: bound Zoom exit, explicit modes, bounded one-to-one host handoff, one-shot mutations, read-back evidence, cancellation and new-meeting isolation")
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

        let soleAttendee = FakeMeetingExitAX(); soleAttendee.requiresHostTransfer = true; soleAttendee.selectedHost = "Synthetic attendee"
        let soleDriver = Driver(transport: soleAttendee, timeout: 1, pollInterval: 1_000_000)
        _ = try await soleDriver.bindCurrentMeeting()
        let transferred = try await soleDriver.exit()
        precondition(transferred.confirmed && soleAttendee.actions == [.press("main-end"), .press("leave"), .press("assign-leave")], "confirm Zoom's existing sole-attendee selection without choosing a person or ending for all")
        precondition(soleAttendee.handoffConfirmedReads >= 2, "host handoff dispatch is not proof of exit")

        let soleRow = FakeMeetingExitAX(); soleRow.requiresHostTransfer = true; soleRow.hostTable = true
        let rowDriver = Driver(transport: soleRow, timeout: 1, pollInterval: 1_000_000)
        _ = try await rowDriver.bindCurrentMeeting()
        let rowOutcome = try await rowDriver.exit()
        precondition(rowOutcome.confirmed && soleRow.actions == [.press("main-end"), .press("leave"), .select("host-row"), .press("assign-leave")], "the observed one-row host table must select once, read back selection, then confirm only self-leave")
        let disabledToolbar = FakeMeetingExitAX(); disabledToolbar.requiresHostTransfer = true; disabledToolbar.hostTable = true; disabledToolbar.disableToolbarUnderModal = true
        let disabledToolbarDriver = Driver(transport: disabledToolbar, timeout: 1, pollInterval: 1_000_000)
        _ = try await disabledToolbarDriver.bindCurrentMeeting()
        let disabledToolbarExit = try await disabledToolbarDriver.exit()
        precondition(disabledToolbarExit.confirmed, "a modal disabling the toolbar does not invalidate its read-only participant count")
        let hiddenToolbar = FakeMeetingExitAX(); hiddenToolbar.requiresHostTransfer = true; hiddenToolbar.hostTable = true; hiddenToolbar.hideToolbarUnderModal = true
        let hiddenToolbarDriver = Driver(transport: hiddenToolbar, timeout: 1, pollInterval: 1_000_000)
        _ = try await hiddenToolbarDriver.bindCurrentMeeting()
        let hiddenToolbarExit = try await hiddenToolbarDriver.exit()
        precondition(hiddenToolbarExit.confirmed && hiddenToolbar.actions == [.press("main-end"), .press("leave"), .select("host-row"), .press("assign-leave")], "the actual Zoom host dialog hides the entire toolbar: preserve the immediately verified two-person count and recheck the live sole candidate")
        let newParticipant = FakeMeetingExitAX(); newParticipant.requiresHostTransfer = true; newParticipant.hostTable = true; newParticipant.participantCountAfterLeave = 3
        let newParticipantDriver = Driver(transport: newParticipant, timeout: 1, pollInterval: 1_000_000)
        _ = try await newParticipantDriver.bindCurrentMeeting()
        try await expect(.handoffChoiceRequired) { _ = try await newParticipantDriver.exit() }
        precondition(newParticipant.actions == [.press("main-end"), .press("leave")], "a freshly visible participant count always overrides the cached count")
        for variant in ["two-rows", "two-tables", "missing-name", "candidate-changed"] {
            let row = FakeMeetingExitAX(); row.requiresHostTransfer = true; row.hostTable = true
            switch variant {
            case "two-rows": row.duplicateHostRow = true
            case "two-tables": row.duplicateHostTable = true
            case "missing-name": row.hostRowName = ""
            default: row.changeHostCandidateAfterSelection = true
            }
            let driver = Driver(transport: row, timeout: 1, pollInterval: 1_000_000)
            _ = try await driver.bindCurrentMeeting()
            try await expect(.handoffRequired) { _ = try await driver.exit() }
            precondition(!row.actions.contains(.press("assign-leave")), "ambiguous or changed table candidates must not receive host control")
        }
        let unselectedRow = FakeMeetingExitAX(); unselectedRow.requiresHostTransfer = true; unselectedRow.hostTable = true; unselectedRow.ignoreHostSelection = true
        let unselectedDriver = Driver(transport: unselectedRow, timeout: 0.04, pollInterval: 1_000_000)
        _ = try await unselectedDriver.bindCurrentMeeting()
        try await expect(.timedOut) { _ = try await unselectedDriver.exit() }
        precondition(unselectedRow.actions == [.press("main-end"), .press("leave"), .select("host-row")], "a row-selection dispatch needs visible readback and cannot be blindly repeated")
        let cancelledRow = FakeMeetingExitAX(); cancelledRow.requiresHostTransfer = true; cancelledRow.hostTable = true
        let cancelledRowDriver = Driver(transport: cancelledRow, timeout: 1, pollInterval: 1_000_000)
        _ = try await cancelledRowDriver.bindCurrentMeeting()
        cancelledRow.onAction = { action in if action == .select("host-row") { cancelledRowDriver.cancel() } }
        try await expect(.cancelled) { _ = try await cancelledRowDriver.exit() }
        precondition(!cancelledRow.actions.contains(.press("assign-leave")), "cancellation during selection must not confirm handoff")
        cancelledRow.onAction = nil
        let retriedRow = try await cancelledRowDriver.exit()
        precondition(retriedRow.confirmed && cancelledRow.actions.filter { $0 == .select("host-row") }.count == 1, "an explicit retry may use visible selected state but cannot repeat row selection")
        let hiddenMain = FakeMeetingExitAX(); hiddenMain.requiresHostTransfer = true; hiddenMain.hostTable = true; hiddenMain.hideMainWhileDialogRemains = true
        let hiddenDriver = Driver(transport: hiddenMain, timeout: 0.04, pollInterval: 1_000_000)
        _ = try await hiddenDriver.bindCurrentMeeting()
        try await expect(.timedOut) { _ = try await hiddenDriver.exit() }
        precondition(hiddenMain.actions == [.press("main-end"), .press("leave")], "a remaining host dialog with an omitted main window must neither claim exit nor act without meeting proof")

        for count in [0, 1, 3, 20] {
            let ambiguousHost = FakeMeetingExitAX(); ambiguousHost.requiresHostTransfer = true; ambiguousHost.selectedHost = "Synthetic attendee"; ambiguousHost.participantCount = count
            let guardedHost = Driver(transport: ambiguousHost, timeout: 1, pollInterval: 1_000_000)
            _ = try await guardedHost.bindCurrentMeeting()
            try await expect(count > 2 ? .handoffChoiceRequired : .handoffRequired) { _ = try await guardedHost.exit() }
            precondition(ambiguousHost.actions == [.press("main-end"), .press("leave")], "one-to-one handoff may not invent or choose an attendee")
        }
        for variant in ["blank-selection", "placeholder", "two-selectors", "two-buttons", "disabled-button", "changed-meeting"] {
            let invalidHost = FakeMeetingExitAX(); invalidHost.requiresHostTransfer = true; invalidHost.selectedHost = "Synthetic attendee"
            switch variant {
            case "blank-selection": invalidHost.selectedHost = "  "
            case "placeholder": invalidHost.selectedHost = "Select a participant"
            case "two-selectors": invalidHost.duplicateHostSelector = true
            case "two-buttons": invalidHost.duplicateHostButton = true
            case "disabled-button": invalidHost.handoffButtonEnabled = false
            default: invalidHost.changeMeetingAfterLeave = true
            }
            let invalidDriver = Driver(transport: invalidHost, timeout: 1, pollInterval: 1_000_000)
            _ = try await invalidDriver.bindCurrentMeeting()
            try await expect(variant == "changed-meeting" ? .changedMeeting : .handoffRequired) { _ = try await invalidDriver.exit() }
            precondition(invalidHost.actions == [.press("main-end"), .press("leave")], "malformed/changed host state must not dispatch transfer")
        }
        let unrelatedHostText = FakeMeetingExitAX(); unrelatedHostText.unrelatedHostText = true
        let unrelatedHostDriver = Driver(transport: unrelatedHostText, timeout: 1, pollInterval: 1_000_000)
        _ = try await unrelatedHostDriver.bindCurrentMeeting()
        let ordinaryExit = try await unrelatedHostDriver.exit()
        precondition(ordinaryExit.confirmed, "host-transfer text in slide content must not block an ordinary exit")

        let uncertainHost = FakeMeetingExitAX(); uncertainHost.requiresHostTransfer = true; uncertainHost.selectedHost = "Synthetic attendee"
        let uncertainHostDriver = Driver(transport: uncertainHost, timeout: 1, pollInterval: 1_000_000)
        _ = try await uncertainHostDriver.bindCurrentMeeting()
        uncertainHost.onAction = { action in if action == .press("assign-leave") { uncertainHostDriver.cancel() } }
        try await expect(.cancelled) { _ = try await uncertainHostDriver.exit() }
        uncertainHost.onAction = nil
        try await expect(.unconfirmedAction) { _ = try await uncertainHostDriver.exit() }
        precondition(uncertainHost.actions == [.press("main-end"), .press("leave"), .press("assign-leave")], "post-dispatch cancellation must not repeat Assign and leave")

        let stalledHost = FakeMeetingExitAX(); stalledHost.requiresHostTransfer = true; stalledHost.selectedHost = "Synthetic attendee"; stalledHost.keepMeetingAfterConfirmation = true
        let stalledHostDriver = Driver(transport: stalledHost, timeout: 0.04, pollInterval: 1_000_000)
        _ = try await stalledHostDriver.bindCurrentMeeting()
        try await expect(.timedOut) { _ = try await stalledHostDriver.exit() }
        try await expect(.timedOut) { _ = try await stalledHostDriver.exit() }
        precondition(stalledHost.actions == [.press("main-end"), .press("leave"), .press("assign-leave")], "host confirmation remains one-shot after an unconfirmed exit")

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
    var selectedHost: String?, participantCount = 2
    var hostTable = false, hostRowSelected = false, duplicateHostRow = false, duplicateHostTable = false
    var hostRowName = "Synthetic sole attendee", changeHostCandidateAfterSelection = false, ignoreHostSelection = false
    var hideMainWhileDialogRemains = false
    var disableToolbarUnderModal = false
    var hideToolbarUnderModal = false
    var participantCountAfterLeave: Int?
    var duplicateHostSelector = false, duplicateHostButton = false, handoffButtonEnabled = true
    var changeMeetingAfterLeave = false, unrelatedHostText = false, handoffConfirmed = false, handoffConfirmedReads = 0
    var meetingID = "meeting-one", windowID = "bound-main-window", info = "Synthetic dedicated meeting"
    var confirmedReads = 0
    var onAction: ((ZoomSlidesAXAction) -> Void)?
    func read(pid: pid_t?, deadline: Date, cancelled: () throws -> Void) throws -> ZoomSlidesAXState {
        try cancelled()
        if confirmationPending {
            confirmedReads += 1
            if handoffConfirmed { handoffConfirmedReads += 1 }
            if (requiresHostTransfer ? handoffConfirmedReads >= 2 : confirmedReads >= 2) && !keepMeetingAfterConfirmation { mainVisible = false; dialogVisible = false }
            if hideMainWhileDialogRemains { mainVisible = false }
        }
        var windows: [ZoomSlidesAXWindow] = []
        if mainVisible {
            var main = ZoomSlidesAXWindow(id: windowID, title: "Zoom Meeting", nodes: [
                .init(id: "main", role: "AXWindow", identifier: "zm.meeting.window.main"),
                .init(id: "main-end", role: "AXButton", description: "End", identifier: "leave"),
                .init(id: "mic", role: "AXButton", description: "Unmute my audio"),
                .init(id: "participants", role: "AXButton", description: "Open participants panel, closed, \(participantCount) participants", enabled: !(disableToolbarUnderModal && confirmationPending))])
            if hideToolbarUnderModal && confirmationPending { main.nodes.removeAll { ["main-end", "mic", "participants"].contains($0.id) } }
            if includeIdentity {
                main.nodes += [.init(id: "info", role: "AXButton", description: info, identifier: "MeetingTopBarInfoButton"),
                               .init(id: "web", role: "AXWebArea", url: "https://dg01slides.zoom.us/p/synthetic-deck/60000?mainMeetingID=\(meetingID)")]
            }
            if unrelatedHostText { main.nodes.append(.init(id: "material", role: "AXStaticText", value: "Assign a new host to demonstrate a future product.")) }
            windows.append(main)
        }
        if dialogVisible {
            var nodes: [ZoomSlidesAXNode] = [.init(id: "dialog", role: "AXWindow", identifier: "zm.meeting.window.leave"),
                .init(id: "cancel", role: "AXButton", description: "Cancel", identifier: "zm.meeting.leavemeeting.cancelButton")]
            if confirmationPending && requiresHostTransfer {
                nodes.append(.init(id: "assign-host", role: "AXStaticText", value: "Assign a new host"))
                if hostTable {
                    nodes += [.init(id: "host-scroll", role: "AXScrollArea", parentID: "dialog"),
                              .init(id: "host-table", role: "AXTable", parentID: "host-scroll"),
                              .init(id: "host-row", role: "AXRow", selected: hostRowSelected, parentID: "host-table"),
                              .init(id: "host-cell", role: "AXCell", parentID: "host-row"),
                              .init(id: "host-name", role: "AXStaticText", value: hostRowName, parentID: "host-cell"),
                              .init(id: "assign-leave", role: "AXButton", description: "Assign and leave", enabled: hostRowSelected)]
                    if duplicateHostRow { nodes.append(.init(id: "other-host-row", role: "AXRow", parentID: "host-table")) }
                    if duplicateHostTable { nodes.append(.init(id: "other-host-table", role: "AXTable", parentID: "host-scroll")) }
                } else if let selectedHost {
                    nodes.append(.init(id: "host-selector", role: "AXPopUpButton", value: selectedHost))
                    if duplicateHostSelector { nodes.append(.init(id: "other-host-selector", role: "AXPopUpButton", value: "Synthetic different attendee")) }
                    nodes.append(.init(id: "assign-leave", role: "AXButton", description: "Assign and leave", enabled: handoffButtonEnabled))
                    if duplicateHostButton { nodes.append(.init(id: "other-assign-leave", role: "AXButton", description: "Assign and leave")) }
                }
            }
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
        case .press("leave"), .press("end-all"):
            confirmationPending = true
            if let participantCountAfterLeave { participantCount = participantCountAfterLeave }
            if changeMeetingAfterLeave { meetingID = "meeting-replaced-before-handoff" }
        case .press("assign-leave"): handoffConfirmed = true
        case .select("host-row"):
            if !ignoreHostSelection { hostRowSelected = true }
            if changeHostCandidateAfterSelection { hostRowName = "Synthetic replacement attendee" }
        default: preconditionFailure("unexpected exit action: \(action)")
        }
        onAction?(action)
        try cancelled() // The native transport may detect cancellation after dispatch.
    }
}
