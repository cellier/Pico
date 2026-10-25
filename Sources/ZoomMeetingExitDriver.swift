import Foundation
import CryptoKit

/// Executes only an explicitly selected exit mode for one bound local meeting.
/// It can hand off to the only other attendee in a one-to-one meeting, and
/// never treats a dispatched action as proof of exit.
actor ZoomMeetingExitDriver {
    enum Mode: String, Sendable { case leave, endForAll }
    struct Binding: Equatable, Sendable {
        let id: UUID
        let pid: pid_t
        let meetingWindow: String
        let meetingTitle: String
        let meetingID: String?
        let meetingInfoFingerprint: String?
    }
    struct Outcome: Equatable, Sendable {
        let mode: Mode
        let pid: pid_t
        let confirmed: Bool
    }
    enum Failure: Error, LocalizedError, Equatable {
        case busy, cancelled, notBound, noMeeting, identityUnavailable, changedMeeting
        case ambiguousControl, unrelatedDialog, handoffRequired, handoffChoiceRequired, endForAllUnavailable, unconfirmedAction, timedOut
        var errorDescription: String? {
            switch self {
            case .busy: return "另一项会议退出操作尚未结束。"
            case .cancelled: return "会议退出操作已取消。"
            case .notBound: return "尚未绑定这场 Zoom 会议，未执行退出。"
            case .noMeeting: return "未找到唯一的进行中 Zoom 会议。"
            case .identityUnavailable: return "无法确认原会议身份，未执行退出。"
            case .changedMeeting: return "Zoom 已切换会议或窗口，未对新会议执行操作。"
            case .ambiguousControl: return "无法唯一确认会议退出按钮，未继续操作。"
            case .unrelatedDialog: return "已有会议退出弹窗不属于本次操作，请本人处理。"
            case .handoffRequired: return "Zoom 要求交接主持人，但无法确认唯一且已选中的接任者；请在 Zoom 中完成交接。"
            case .handoffChoiceRequired: return "会议中还有多位参会者，请在 Zoom 中选择接任主持人后离开。"
            case .endForAllUnavailable: return "当前无法确认“为所有人结束”按钮，未改为其他退出方式。"
            case .unconfirmedAction: return "退出按钮的执行结果尚未确认，未重复点击，请本人检查 Zoom。"
            case .timedOut: return "尚未确认原会议窗口消失，退出操作已暂停，请本人检查 Zoom。"
            }
        }
    }
    private let transport: any ZoomSlidesAXTransport
    private let cancellation = MeetingExitCancellation()
    private let timeout: TimeInterval
    private let pollInterval: UInt64
    private var binding: Binding?
    private var operating = false
    private var ownedDialogID: UUID?
    private var openingAttemptID: UUID?
    private var confirmationAttemptID: UUID?
    private var confirmationID: UUID?
    private var handoffAttemptID: UUID?
    private var handoffConfirmationID: UUID?
    private var handoffSelectionAttemptID: UUID?
    private var handoffCandidateFingerprint: String?
    private var lastParticipantCounts: (bindingID: UUID, counts: Set<Int>, at: Date)?

    init(timeout: TimeInterval = 15, pollInterval: UInt64 = 120_000_000) {
        transport = ZoomSlidesSystemAXTransport(includeExitDialogs: true)
        self.timeout = max(1, min(timeout, 30)); self.pollInterval = pollInterval
    }
    init(transport: any ZoomSlidesAXTransport, timeout: TimeInterval = 15, pollInterval: UInt64 = 120_000_000) {
        self.transport = transport; self.timeout = max(0.02, min(timeout, 30)); self.pollInterval = pollInterval
    }
    /// Stops pending work; it does not click Cancel, forget the binding, or undo a
    /// confirmation already dispatched. A later explicit exit verifies the same binding.
    nonisolated func cancel() { cancellation.cancel() }

    func bindCurrentMeeting() async throws -> Binding {
        guard !operating else { throw Failure.busy }
        operating = true; defer { operating = false }
        let token = cancellation.renew(), deadline = Date().addingTimeInterval(timeout)
        binding = nil; ownedDialogID = nil; openingAttemptID = nil; confirmationAttemptID = nil; confirmationID = nil
        handoffAttemptID = nil; handoffConfirmationID = nil
        handoffSelectionAttemptID = nil; handoffCandidateFingerprint = nil
        lastParticipantCounts = nil
        let state = try read(pid: nil, token: token, deadline: deadline)
        let candidates = state.windows.filter(ZoomSlidesDriver.isMeeting)
        guard candidates.count == 1, let main = candidates.first else { throw Failure.noMeeting }
        let proof = try Self.identity(main)
        guard proof.meetingID != nil || proof.fingerprint != nil else { throw Failure.identityUnavailable }
        let bound = Binding(id: UUID(), pid: state.pid, meetingWindow: main.id, meetingTitle: main.title,
                            meetingID: proof.meetingID, meetingInfoFingerprint: proof.fingerprint)
        try cancellation.check(token)
        binding = bound
        return bound
    }

    func exit(mode: Mode = .leave) async throws -> Outcome {
        guard !operating else { throw Failure.busy }
        guard let bound = binding else { throw Failure.notBound }
        operating = true; defer { operating = false }
        let token = cancellation.renew(), deadline = Date().addingTimeInterval(timeout)
        var opened = openingAttemptID == bound.id, confirmed = confirmationID == bound.id
        while true {
            let state = try read(pid: bound.pid, token: token, deadline: deadline)
            let main = state.windows.first { $0.id == bound.meetingWindow }
            let otherMeetings = state.windows.filter { $0.id != bound.meetingWindow && Self.hasMainIdentifier($0) }
            guard otherMeetings.isEmpty else { throw Failure.changedMeeting }
            let dialogs = state.windows.filter(Self.isExitDialog)
            guard dialogs.count <= 1 else { throw Failure.ambiguousControl }
            guard let main else {
                guard confirmed else { throw Failure.changedMeeting }
                if !dialogs.isEmpty {
                    guard ownedDialogID == bound.id else { throw Failure.unrelatedDialog }
                    // A still-open host/exit dialog is not a completed departure,
                    // even if Zoom temporarily omits the main window behind it.
                    try await poll(token: token, deadline: deadline)
                    continue
                }
                try cancellation.check(token)
                return .init(mode: mode, pid: bound.pid, confirmed: true)
            }
            try Self.verify(bound, state: state, main: main, requireProof: !confirmed)
            let currentCounts = Self.participantCounts(in: main)
            if !currentCounts.isEmpty { lastParticipantCounts = (bound.id, currentCounts, Date()) }
            // An AX call may have clicked before throwing cancellation or a
            // transport error. Never dispatch that destructive confirmation twice.
            if confirmationAttemptID == bound.id && !confirmed { throw Failure.unconfirmedAction }
            if handoffAttemptID == bound.id && handoffConfirmationID != bound.id { throw Failure.unconfirmedAction }
            if confirmed {
                if mode == .leave, let dialog = dialogs.first, Self.requiresHandoff(dialog), handoffConfirmationID != bound.id {
                    guard ownedDialogID == bound.id else { throw Failure.unrelatedDialog }
                    // Leaving as host can open a second confirmation. This is a
                    // distinct one-shot action, never a retry of Leave meeting.
                    // Recheck full meeting proof before transferring any control.
                    try Self.verify(bound, state: state, main: main, requireProof: true)
                    // Zoom removes the whole toolbar while its host dialog is
                    // open. Retain only this binding's count observed immediately
                    // before leaving; the live table must still have one candidate.
                    let counts = lastParticipantCounts.flatMap { cached -> Set<Int>? in
                        cached.bindingID == bound.id && Date().timeIntervalSince(cached.at) <= 15 ? cached.counts : nil
                    } ?? []
                    let step = try Self.singleAttendeeHandoff(in: dialog, participantCounts: counts)
                    if let previous = handoffCandidateFingerprint, previous != step.fingerprint { throw Failure.handoffRequired }
                    try cancellation.check(token)
                    if step.needsSelection {
                        if handoffSelectionAttemptID != bound.id {
                            handoffSelectionAttemptID = bound.id; handoffCandidateFingerprint = step.fingerprint
                            try transport.perform(.select(step.id), pid: bound.pid, deadline: deadline, cancelled: { try self.cancellation.check(token) })
                        }
                    } else {
                        handoffAttemptID = bound.id
                        try transport.perform(.press(step.id), pid: bound.pid, deadline: deadline, cancelled: { try self.cancellation.check(token) })
                        handoffConfirmationID = bound.id
                    }
                }
                try await poll(token: token, deadline: deadline)
                continue
            }
            if let dialog = dialogs.first {
                guard ownedDialogID == bound.id else { throw Failure.unrelatedDialog }
                let identifier = mode == .leave ? "zm.meeting.leavemeeting.leaveMeetingButton" : "zm.meeting.leavemeeting.endMeetingButton"
                let controls = dialog.nodes.filter { $0.role == "AXButton" && $0.enabled && $0.identifier == identifier }
                guard controls.count == 1, let control = controls.first else {
                    if mode == .leave && Self.requiresHandoff(dialog) { throw Failure.handoffRequired }
                    throw mode == .endForAll ? Failure.endForAllUnavailable : Failure.ambiguousControl
                }
                try cancellation.check(token)
                confirmationAttemptID = bound.id
                try transport.perform(.press(control.id), pid: bound.pid, deadline: deadline, cancelled: { try self.cancellation.check(token) })
                confirmationID = bound.id; confirmed = true
            } else if !opened {
                guard ZoomSlidesDriver.isMeeting(main) else { throw Failure.identityUnavailable }
                let controls = main.nodes.filter { $0.role == "AXButton" && $0.enabled && ["leave", "idleave"].contains($0.identifier) && $0.named(["End", "Leave", "End Meeting", "Leave Meeting", "结束", "离开", "结束会议", "离开会议"]) }
                guard controls.count == 1, let control = controls.first else { throw Failure.ambiguousControl }
                try cancellation.check(token)
                openingAttemptID = bound.id; ownedDialogID = bound.id; opened = true
                try transport.perform(.press(control.id), pid: bound.pid, deadline: deadline, cancelled: { try self.cancellation.check(token) })
            }
            try await poll(token: token, deadline: deadline)
        }
    }
    private func read(pid: pid_t?, token: UInt64, deadline: Date) throws -> ZoomSlidesAXState {
        try cancellation.check(token)
        guard Date() < deadline else { throw Failure.timedOut }
        let result = try transport.read(pid: pid, deadline: deadline, cancelled: { try self.cancellation.check(token) })
        guard result.complete else { throw Failure.identityUnavailable }
        if let pid, result.pid != pid { throw Failure.changedMeeting }
        try cancellation.check(token)
        return result
    }
    private func poll(token: UInt64, deadline: Date) async throws {
        try cancellation.check(token)
        guard Date() < deadline else { throw Failure.timedOut }
        try await Task.sleep(nanoseconds: pollInterval)
        try cancellation.check(token)
    }
    private static func hasMainIdentifier(_ window: ZoomSlidesAXWindow) -> Bool {
        window.nodes.contains { $0.identifier == "zm.meeting.window.main" }
    }
    private static func identity(_ main: ZoomSlidesAXWindow) throws -> (meetingID: String?, fingerprint: String?) {
        let ids = Set(main.nodes.compactMap(\.url).compactMap(URL.init(string:)).filter { ZoomSlidesDriver.documentID($0) != nil }
            .compactMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }.flatMap { $0.queryItems ?? [] }
            .filter { $0.name == "mainMeetingID" }.compactMap(\.value).filter { !$0.isEmpty })
        guard ids.count <= 1 else { throw Failure.identityUnavailable }
        let info = main.nodes.filter { $0.identifier == "MeetingTopBarInfoButton" }.flatMap { [$0.title, $0.description, $0.value] }.filter { !$0.isEmpty }
        let canonical = info.map(ZoomSlidesDriver.normalized).joined(separator: "\n")
        let fingerprint = canonical.isEmpty ? nil : SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return (ids.first, fingerprint)
    }
    private static func verify(_ bound: Binding, state: ZoomSlidesAXState, main: ZoomSlidesAXWindow, requireProof: Bool) throws {
        guard state.pid == bound.pid, main.id == bound.meetingWindow, (!requireProof || hasMainIdentifier(main)),
              ZoomSlidesDriver.normalized(main.title) == ZoomSlidesDriver.normalized(bound.meetingTitle) else { throw Failure.changedMeeting }
        let proof = try identity(main)
        if let old = bound.meetingID, let current = proof.meetingID, old != current { throw Failure.changedMeeting }
        if let old = bound.meetingInfoFingerprint, let current = proof.fingerprint, old != current { throw Failure.changedMeeting }
        let idVerified = bound.meetingID != nil && bound.meetingID == proof.meetingID
        let infoVerified = bound.meetingInfoFingerprint != nil && bound.meetingInfoFingerprint == proof.fingerprint
        if requireProof && !idVerified && !infoVerified { throw Failure.identityUnavailable }
    }
    private static func isExitDialog(_ window: ZoomSlidesAXWindow) -> Bool {
        window.nodes.contains { $0.identifier == "zm.meeting.window.leave" || $0.identifier.hasPrefix("zm.meeting.window.leave.") }
    }
    private static let handoffNames = ["Assign and leave", "Assign and Leave", "指定并离开", "分配并离开", "指派并离开"]
    private static func requiresHandoff(_ dialog: ZoomSlidesAXWindow) -> Bool {
        // Materials and unrelated meeting controls can mention host transfer.
        // Only our owned exit dialog may establish this second exit phase.
        dialog.nodes.flatMap(\.text).contains { text in
            let value = ZoomSlidesDriver.normalized(text)
            return (value.contains("host") && ["assign", "transfer", "choose a new"].contains(where: value.contains))
                || (value.contains("主持人") && ["指定", "移交", "转让"].contains(where: value.contains))
        } || dialog.nodes.contains { $0.role == "AXButton" && $0.named(handoffNames) }
    }
    private struct HandoffStep { var id: String; var needsSelection: Bool; var fingerprint: String }
    private static func participantCounts(in main: ZoomSlidesAXWindow) -> Set<Int> {
        // Modal exit windows can disable the meeting toolbar behind them. Its
        // participant count remains read-only evidence; no toolbar action is sent.
        Set(main.nodes.filter { ["AXButton", "AXMenuButton"].contains($0.role) }.flatMap(\.text).compactMap(participantCount))
    }
    private static func singleAttendeeHandoff(in dialog: ZoomSlidesAXWindow, participantCounts counts: Set<Int>) throws -> HandoffStep {
        if counts.count == 1, let count = counts.first, count > 2 { throw Failure.handoffChoiceRequired }
        guard counts == [2] else { throw Failure.handoffRequired }
        let selectors = dialog.nodes.filter { $0.enabled && ["AXPopUpButton", "AXComboBox"].contains($0.role) }
        let controls = dialog.nodes.filter { $0.role == "AXButton" && $0.named(handoffNames) }
        guard controls.count == 1, let control = controls.first else { throw Failure.handoffRequired }
        let tables = dialog.nodes.filter { $0.role == "AXTable" }
        if selectors.isEmpty, tables.count == 1, let table = tables.first {
            let byID = Dictionary(uniqueKeysWithValues: dialog.nodes.map { ($0.id, $0) })
            func isDescendant(_ node: ZoomSlidesAXNode, of ancestor: String) -> Bool {
                var parent = node.parentID, seen = Set<String>()
                while let id = parent, seen.insert(id).inserted {
                    if id == ancestor { return true }; parent = byID[id]?.parentID
                }
                return false
            }
            let rows = dialog.nodes.filter { $0.role == "AXRow" && isDescendant($0, of: table.id) }
            guard rows.count == 1, let row = rows.first, row.enabled else { throw Failure.handoffRequired }
            let labels = dialog.nodes.filter { $0.role == "AXStaticText" && isDescendant($0, of: row.id) }.flatMap(\.text).map(ZoomSlidesDriver.normalized).filter { !$0.isEmpty }
            guard !labels.isEmpty else { throw Failure.handoffRequired }
            let fingerprint = SHA256.hash(data: Data(labels.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
            if !row.selected { return .init(id: row.id, needsSelection: true, fingerprint: fingerprint) }
            guard control.enabled else { throw Failure.handoffRequired }
            return .init(id: control.id, needsSelection: false, fingerprint: fingerprint)
        }
        guard tables.isEmpty, selectors.count == 1, let selector = selectors.first, control.enabled else { throw Failure.handoffRequired }
        let value = selector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["select", "choose", "select a participant", "choose a participant", "select a host", "choose a host", "选择参会者", "选择主持人"]
        guard !value.isEmpty, value.count <= 200, !placeholders.contains(ZoomSlidesDriver.normalized(value)) else { throw Failure.handoffRequired }
        // A selector already names the only other attendee. Do not expand it or
        // choose a name; more participants always require the owner's choice.
        let fingerprint = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return .init(id: control.id, needsSelection: false, fingerprint: fingerprint)
    }
    private static func participantCount(_ text: String) -> Int? {
        let value = ZoomSlidesDriver.normalized(text)
        let pattern = #"^open participants panel, (?:closed|opened|open), ([0-9]{1,5}) participants?$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return Int(value[range])
    }
}

private final class MeetingExitCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    func renew() -> UInt64 { lock.lock(); defer { lock.unlock() }; epoch &+= 1; return epoch }
    func cancel() { lock.lock(); epoch &+= 1; lock.unlock() }
    func check(_ token: UInt64) throws {
        lock.lock(); let valid = epoch == token; lock.unlock()
        if !valid || Task.isCancelled { throw ZoomMeetingExitDriver.Failure.cancelled }
    }
}
