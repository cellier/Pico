import AppKit
import ApplicationServices
import Foundation

/// Local, bounded UI automation. This driver never calls a model, joins a meeting,
/// accepts a system permission, or executes model-supplied code.
actor ZoomSlidesDriver {
    struct Target: Equatable, Sendable {
        var url: URL
        var title: String
        var meetingTitle: String?
        var totalSlides: Int?
        var documentID: String? { ZoomSlidesDriver.documentID(url) }
        init(url: URL, title: String, meetingTitle: String? = nil, totalSlides: Int? = nil) {
            self.url = url; self.title = title; self.meetingTitle = meetingTitle; self.totalSlides = totalSlides
        }
    }
    enum SharingState: String, Sendable { case inactive, active, unknown }
    struct Snapshot: Equatable, Sendable {
        var pid: pid_t
        var meetingTitle: String
        var documentTitle: String?
        var currentSlide: Int?
        var totalSlides: Int?
        var sharing: SharingState
        var documentID: String? = nil
    }
    enum Failure: Error, LocalizedError, Equatable {
        case cancelled, busy, permissionRequired, zoomNotRunning, ambiguousMeeting
        case meetingChanged, documentMismatch, invalidTarget, invalidSlide, unavailable(String), timedOut(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "幻灯片操作已取消。"
            case .busy: return "另一个幻灯片操作尚未结束。"
            case .permissionRequired: return "需要在 macOS 中正常授予 Pico 辅助功能权限。"
            case .zoomNotRunning: return "未找到正在运行的 Zoom。"
            case .ambiguousMeeting: return "无法唯一确认目标 Zoom 会议，未执行操作。"
            case .meetingChanged: return "目标 Zoom 会议或进程已变化，幻灯片操作已停止。"
            case .documentMismatch: return "当前文稿与本场配置不符，未继续操作。"
            case .invalidTarget: return "请提供明确的 Zoom Slides HTTPS 链接和文稿标题。"
            case .invalidSlide: return "页码超出文稿范围。"
            case .unavailable(let message): return message
            case .timedOut(let message): return "幻灯片操作超时：" + message
            }
        }
    }

    private let transport: any ZoomSlidesAXTransport
    private nonisolated let cancellation = ZoomSlidesCancellation()
    private let timeout: TimeInterval
    private let sharingTimeout: TimeInterval
    private let navigationTimeout: TimeInterval
    private let pollInterval: UInt64
    private var binding: ZoomSlidesBinding?
    private var target: Target?
    private var operating = false
    private var meetingID: String?

    init(timeout: TimeInterval = 15, pollInterval: UInt64 = 120_000_000) {
        self.transport = ZoomSlidesSystemAXTransport()
        self.timeout = max(0.2, min(timeout, 15)); self.pollInterval = pollInterval
        self.sharingTimeout = 45; self.navigationTimeout = 30
    }
    init(transport: any ZoomSlidesAXTransport, timeout: TimeInterval = 15, pollInterval: UInt64 = 120_000_000, operationBudget: TimeInterval? = nil) {
        self.transport = transport
        self.timeout = max(0.02, min(timeout, 15)); self.pollInterval = pollInterval
        self.sharingTimeout = min(45, max(0.02, operationBudget ?? 45)); self.navigationTimeout = min(30, max(0.02, operationBudget ?? 30))
    }
    /// Invalidates pending actions immediately, including operations currently awaiting read-back.
    /// It deliberately does not stop sharing or navigate away from the visible slide.
    nonisolated func cancel() { cancellation.cancel() }

    func preflight(target: Target) async throws -> Snapshot {
        let (ticket, deadline) = try begin(); defer { operating = false }
        try configure(target)
        return try inspect(read(ticket, deadline), target: target).snapshot
    }
    func readStatus() async throws -> Snapshot {
        let (ticket, deadline) = try begin(); defer { operating = false }
        guard let target else { throw Failure.invalidTarget }
        return try inspect(read(ticket, deadline), target: target).snapshot
    }
    func startSharing(target: Target) async throws -> Snapshot {
        let (ticket, deadline) = try begin(budget: sharingTimeout); defer { operating = false }
        try configure(target)
        var opened = false, submitted = false, confirmed = false, tabs = 0, selected = false
        var chosePresent = false, disabledPersistent = false
        var emptyFilesDeadline: Date?
        while true {
            let state = try read(ticket, deadline), status = try inspect(state, target: target)
            if status.snapshot.sharing == .active { return status.snapshot }
            if status.snapshot.sharing == .unknown && !opened { throw Failure.unavailable("已有共享状态无法确认，未重新发起共享。") }
            let permissions = state.windows.filter { $0.nodes.contains { $0.named(["How do you want to share?"]) } }
            let pickers = state.windows.filter { Self.isSharePicker($0.title) || $0.nodes.prefix(1).flatMap(\.text).contains(where: Self.isSharePicker) }
            if !permissions.isEmpty {
                guard opened && submitted && permissions.count == 1 else { throw Failure.unavailable("共享权限窗口不属于本次操作，未确认。") }
                let nodes = permissions[0].nodes
                let present = nodes.filter { $0.enabled && ["AXButton", "AXRadioButton"].contains($0.role) && $0.text.contains { Self.normalized($0).hasPrefix("present, present with private speaker notes.") } }
                guard present.count == 1, let choice = present.first, let presentChecked = checked(choice) else { throw Failure.unavailable("无法确认仅演示权限，未共享。") }
                if !presentChecked {
                    guard !chosePresent else { try await poll(ticket, deadline); continue }
                    try await performSharing(.press(choice.id), expecting: .presentSelected, target: target, ticket: ticket, deadline: deadline); chosePresent = true; continue
                }
                let persistent = try Self.uniqueNode(in: permissions, roles: ["AXCheckBox"], names: ["Allow persistent access to verified meeting participants after closing the presentation"])
                guard let persistentChecked = checked(persistent) else { throw Failure.unavailable("无法确认关闭演示后的持久访问权限。") }
                if persistentChecked {
                    guard !disabledPersistent else { try await poll(ticket, deadline); continue }
                    try await performSharing(.press(persistent.id), expecting: .persistentDisabled, target: target, ticket: ticket, deadline: deadline); disabledPersistent = true; continue
                }
                if !confirmed {
                    let share = try Self.uniqueNode(in: permissions, roles: ["AXButton"], names: ["Share presentation"])
                    try await performSharing(.press(share.id), expecting: .targetActive, target: target, ticket: ticket, deadline: deadline); confirmed = true; continue
                }
            } else if !pickers.isEmpty {
                guard pickers.count == 1, opened else { throw Failure.unavailable("共享选择器不属于本次操作，未继续。") }
                if submitted { try await poll(ticket, deadline); continue }
                let picker = pickers[0]
                if let action = try ZoomSharePickerTabs.filesAction(in: picker) {
                    guard tabs < 3 else { throw Failure.unavailable("共享选择器未切换到 Files，未继续共享。") }
                    try perform(action, ticket, deadline); tabs += 1
                    try await poll(ticket, deadline); continue
                }
                let files = picker.nodes.filter { node in
                    node.enabled && ["AXCell", "AXRow", "AXButton"].contains(node.role) && node.text.contains { Self.normalized($0).hasPrefix(Self.normalized("Slides, " + target.title + ",")) }
                }
                let rows = Dictionary(grouping: files.map { node -> ZoomSlidesAXNode in
                    var current = node, seen = Set<String>()
                    while let parent = current.parentID, seen.insert(parent).inserted, let ancestor = picker.nodes.first(where: { $0.id == parent }) {
                        if ancestor.role == "AXRow" { return ancestor }
                        current = ancestor
                    }
                    return node
                }, by: \.id).values.compactMap(\.first)
                if rows.isEmpty {
                    // Files can become the selected tab before its recent rows are
                    // populated. Re-read only; never share using the footer alone.
                    let now = Date()
                    let loadingDeadline = emptyFilesDeadline ?? min(deadline, now.addingTimeInterval(2))
                    emptyFilesDeadline = loadingDeadline
                    guard now < loadingDeadline else { throw Failure.unavailable("Zoom 近期文件列表中尚未显示目标幻灯片。请先在 Zoom 打开指定文稿后重试；未共享其他文件。") }
                    try await poll(ticket, deadline)
                    continue
                }
                guard rows.count == 1, let row = rows.first else { throw Failure.unavailable("未找到唯一的目标幻灯片文件，未共享同名文件。") }
                let footer = picker.nodes.filter { $0.enabled && $0.role == "AXButton" && $0.named(["Share - " + target.title]) }
                if footer.count == 1, let share = footer.first {
                    // The footer names the selected file. The live WebArea URL is independently
                    // checked below before any narration may start.
                    try await performSharing(.press(share.id), expecting: .permissionPaneOrTargetActive, target: target, ticket: ticket, deadline: deadline); submitted = true; continue
                }
                if selected { try await poll(ticket, deadline); continue }
                try perform(.select(row.id), ticket, deadline); selected = true
            } else if !opened {
                guard let binding, let meeting = state.windows.first(where: { $0.id == binding.meetingWindow }) else { throw Failure.meetingChanged }
                let shares = meeting.nodes.filter { $0.enabled && $0.role == "AXButton" && ($0.identifier == "idshare" || $0.named(["Share"])) }
                guard shares.count == 1, let share = shares.first else { throw Failure.unavailable("无法唯一确认本场会议的共享按钮。") }
                try await performSharing(.press(share.id), expecting: .pickerOpened, target: target, ticket: ticket, deadline: deadline); opened = true
            }
            try await poll(ticket, deadline)
        }
    }
    func goToSlide(_ number: Int) async throws -> Snapshot {
        let (ticket, deadline) = try begin(budget: navigationTimeout); defer { operating = false }
        guard let target, number >= 1 else { throw Failure.invalidSlide }
        var state = try read(ticket, deadline), status = try inspect(state, target: target)
        guard status.snapshot.sharing == .active, let total = status.snapshot.totalSlides, number <= total else { throw Failure.invalidSlide }
        var moves = 0
        while status.snapshot.currentSlide != number {
            guard let current = status.snapshot.currentSlide, moves < total else { throw Failure.unavailable("无法确认当前幻灯片页码。") }
            let direction = number > current ? 1 : -1
            let control = try Self.uniqueNode(in: [.init(id: "presentation", title: target.title, nodes: status.presentationNodes)], roles: ["AXButton"], names: [direction > 0 ? "next" : "previous"])
            try perform(.press(control.id), ticket, deadline); moves += 1
            repeat {
                try await poll(ticket, deadline)
                state = try read(ticket, deadline); status = try inspect(state, target: target)
                guard status.snapshot.sharing != .inactive else { throw Failure.unavailable("目标幻灯片已不在共享，翻页已停止。") }
            } while status.snapshot.sharing == .unknown || status.snapshot.currentSlide == current
            guard status.snapshot.currentSlide == current + direction else { throw Failure.unavailable("实际页码与本次翻页不一致，已停止自动操作。") }
        }
        return status.snapshot
    }

    private func begin(budget: TimeInterval? = nil) throws -> (UInt64, Date) {
        guard !operating else { throw Failure.busy }
        operating = true
        return (cancellation.token(), Date().addingTimeInterval(budget ?? timeout))
    }
    private func configure(_ value: Target) throws {
        guard value.documentID != nil, !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.title.count <= 200,
              value.totalSlides.map({ (1...10000).contains($0) }) != false else { throw Failure.invalidTarget }
        target = value
    }
    private func read(_ ticket: UInt64, _ deadline: Date) throws -> ZoomSlidesAXState {
        try cancellation.check(ticket)
        guard Date() < deadline else { throw Failure.timedOut("等待 Zoom 读回共享或页码") }
        let readDeadline = min(deadline, Date().addingTimeInterval(timeout))
        let state = try transport.read(pid: binding?.pid, deadline: readDeadline, cancelled: { try self.cancellation.check(ticket) })
        binding = try Self.bindMeeting(state, title: target?.meetingTitle, previous: binding)
        return state
    }
    private func perform(_ action: ZoomSlidesAXAction, _ ticket: UInt64, _ deadline: Date) throws {
        try cancellation.check(ticket)
        guard let binding else { throw Failure.meetingChanged }
        try transport.perform(action, pid: binding.pid, deadline: deadline, cancelled: { try self.cancellation.check(ticket) })
    }
    private enum SharingPostcondition { case pickerOpened, permissionPaneOrTargetActive, presentSelected, persistentDisabled, targetActive }
    /// A Zoom button can change the modal before replying with an AX failure. Only
    /// the pending action's semantic result can recover that error; never click it again.
    private func performSharing(_ action: ZoomSlidesAXAction, expecting expected: SharingPostcondition,
                                target: Target, ticket: UInt64, deadline: Date) async throws {
        do { try perform(action, ticket, deadline); return }
        catch let actionError as Failure {
            guard case .unavailable = actionError else { throw actionError }
            let readbackDeadline = min(deadline, Date().addingTimeInterval(2))
            while Date() < readbackDeadline {
                let state: ZoomSlidesAXState
                do { state = try read(ticket, readbackDeadline) }
                catch let readError as Failure {
                    if case .timedOut = readError, Date() >= readbackDeadline { break }
                    throw readError
                }
                let status = try inspect(state, target: target).snapshot
                let permissions = permissionState(in: state)
                let matched: Bool
                switch expected {
                case .pickerOpened:
                    let pickers = state.windows.filter { Self.isSharePicker($0.title) || $0.nodes.prefix(1).flatMap(\.text).contains(where: Self.isSharePicker) }
                    if pickers.count == 1 {
                        do { _ = try ZoomSharePickerTabs.filesAction(in: pickers[0]); matched = true }
                        catch { matched = false }
                    } else { matched = false }
                case .permissionPaneOrTargetActive: matched = permissions != nil || status.sharing == .active
                case .presentSelected: matched = permissions?.present == true
                case .persistentDisabled: matched = permissions?.persistent == false
                case .targetActive: matched = status.sharing == .active
                }
                if matched { return }
                try cancellation.check(ticket)
                let remaining = readbackDeadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                try await Task.sleep(nanoseconds: min(pollInterval, UInt64(remaining * 1_000_000_000)))
            }
            try cancellation.check(ticket)
            throw actionError
        }
    }
    private func permissionState(in state: ZoomSlidesAXState) -> (present: Bool, persistent: Bool)? {
        let panes = state.windows.filter { $0.nodes.contains { $0.named(["How do you want to share?"]) } }
        guard panes.count == 1 else { return nil }
        let nodes = panes[0].nodes
        let present = nodes.filter { $0.enabled && ["AXButton", "AXRadioButton"].contains($0.role) && $0.text.contains { Self.normalized($0).hasPrefix("present, present with private speaker notes.") } }
        let persistent = nodes.filter { $0.enabled && $0.role == "AXCheckBox" && $0.named(["Allow persistent access to verified meeting participants after closing the presentation"]) }
        let share = nodes.filter { $0.enabled && $0.role == "AXButton" && $0.named(["Share presentation"]) }
        guard present.count == 1, persistent.count == 1, share.count == 1,
              let presentChecked = checked(present[0]), let persistentChecked = checked(persistent[0]) else { return nil }
        return (presentChecked, persistentChecked)
    }
    private func poll(_ ticket: UInt64, _ deadline: Date) async throws {
        try cancellation.check(ticket)
        guard Date() < deadline else { throw Failure.timedOut("等待 Zoom 读回共享或页码") }
        try await Task.sleep(nanoseconds: pollInterval)
        try cancellation.check(ticket)
    }
    private func checked(_ node: ZoomSlidesAXNode) -> Bool? {
        if node.text.contains(where: { Self.normalized($0).hasSuffix(", not checked") }) { return false }
        if node.text.contains(where: { Self.normalized($0).hasSuffix(", checked") }) { return true }
        return node.checked
    }
    private func inspect(_ state: ZoomSlidesAXState, target: Target) throws -> (snapshot: Snapshot, presentationNodes: [ZoomSlidesAXNode]) {
        guard let binding, let window = state.windows.first(where: { $0.id == binding.meetingWindow }) else { throw Failure.meetingChanged }
        let webAreas = window.nodes.filter { $0.role == "AXWebArea" && $0.url.flatMap(URL.init(string:)).flatMap(Self.documentID) != nil }
        let matching = webAreas.filter { $0.url.flatMap(URL.init(string:)).flatMap(Self.documentID) == target.documentID }
        if webAreas.contains(where: { $0.url.flatMap(URL.init(string:)).flatMap(Self.documentID) != target.documentID }) { throw Failure.documentMismatch }
        var snapshot = Snapshot(pid: state.pid, meetingTitle: binding.meetingTitle, documentTitle: nil, currentSlide: nil, totalSlides: nil, sharing: .inactive)
        guard !matching.isEmpty else {
            if window.nodes.contains(where: { $0.named(["Stop sharing"]) }) { snapshot.sharing = .unknown }
            return (snapshot, [])
        }
        let roots = Set(matching.map(\.id)), byID = Dictionary(uniqueKeysWithValues: window.nodes.map { ($0.id, $0) })
        let nodes = window.nodes.filter { node in
            var current: ZoomSlidesAXNode? = node, seen = Set<String>()
            while let item = current, seen.insert(item.id).inserted {
                if roots.contains(item.id) { return true }
                current = item.parentID.flatMap { byID[$0] }
            }
            return false
        }
        let titleVerified = matching.contains { $0.named([target.title + " - Zoom Slides"]) } || nodes.contains { $0.role == "AXHeading" && $0.named([target.title]) }
        guard titleVerified else { snapshot.sharing = .unknown; return (snapshot, nodes) }
        guard nodes.contains(where: { $0.role == "AXButton" && $0.enabled && $0.named(["Stop sharing"]) }) else { snapshot.sharing = .unknown; return (snapshot, nodes) }
        let slideshowRoots = nodes.filter { $0.text.contains { Self.slideshowCounter($0) != nil } }
        let counters = Set(slideshowRoots.flatMap(\.text).compactMap { Self.slideshowCounter($0) }.map { "\($0.current)/\($0.total)" })
        guard counters.count == 1, let value = counters.first else { snapshot.sharing = .unknown; return (snapshot, []) }
        let slideRoots = Set(slideshowRoots.map(\.id))
        let slideNodes = nodes.filter { node in
            var current: ZoomSlidesAXNode? = node, seen = Set<String>()
            while let item = current, seen.insert(item.id).inserted {
                if slideRoots.contains(item.id) { return true }
                current = item.parentID.flatMap { byID[$0] }
            }
            return false
        }
        // Zoom retains a hidden editor at its original page. Its "Slide 1 / 6" and
        // thumbnail selection are NOT the page currently presented to the audience.
        let speakerCounters = Set(slideNodes.filter { $0.role == "AXButton" }.flatMap(\.text).compactMap { Self.speakerCounter($0) }.map { "\($0.current)/\($0.total)" })
        guard speakerCounters.isEmpty || speakerCounters == counters else { snapshot.sharing = .unknown; return (snapshot, []) }
        let numbers = value.split(separator: "/").compactMap { Int($0) }
        guard numbers.count == 2, target.totalSlides == nil || target.totalSlides == numbers[1] else { throw Failure.documentMismatch }
        let meetingIDs = Set(matching.compactMap { $0.url }.compactMap(URLComponents.init(string:)).flatMap { $0.queryItems ?? [] }.filter { $0.name == "mainMeetingID" }.compactMap(\.value))
        guard meetingIDs.count <= 1 else { throw Failure.meetingChanged }
        if let observed = meetingIDs.first {
            if let meetingID, observed != meetingID { throw Failure.meetingChanged }
            meetingID = observed
        }
        snapshot.documentTitle = target.title; snapshot.documentID = target.documentID
        snapshot.currentSlide = numbers[0]; snapshot.totalSlides = numbers[1]; snapshot.sharing = .active
        return (snapshot, slideNodes)
    }

    static func normalized(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
    static func isSharePicker(_ value: String) -> Bool {
        ["share screen window", "select a window or an application that you want to share", "select a window or application that you want to share", "select a window or an application", "select a window or application"].contains(normalized(value))
    }
    static func windowKind(title: String, description: String, identifier: String, includeExitDialogs: Bool = false) -> String? {
        if includeExitDialogs && (identifier == "zm.meeting.window.leave" || identifier.hasPrefix("zm.meeting.window.leave.")) { return "meeting-exit-dialog" }
        if identifier == "zm.meeting.window.main" || title == "Zoom Meeting" { return "main-meeting" }
        if isSharePicker(title) || isSharePicker(description) { return "share-picker" }
        return nil
    }
    static func permitsMissingDescriptor(_ name: String, error: AXError, role: String?, supportedAttributes: [String]?, childrenRead: Bool = false, identityRead: Bool = false, identifier: String? = nil, hasURL: Bool = false, presentationContent: Bool = false, windowType: String? = nil, hasNonemptyURL: Bool? = nil) -> Bool {
        guard [kAXTitleAttribute, kAXDescriptionAttribute].contains(name), [.failure, .notImplemented, .illegalArgument].contains(error) else { return false }
        // A public names query can prove a descriptor absent, independently of
        // the generic error. This is not an inference from a failed read alone.
        if let supportedAttributes, !supportedAttributes.contains(name) { return true }
        // Share-flow text areas and list containers are supplemental metadata, never selectable files,
        // action controls or live slide proof. Zoom gives these text areas opaque
        // identifiers (and sometimes fails that optional identifier read too).
        // Neither case makes their description required. Preserve successful
        // text/identity and every child, with document and exit proof excluded.
        let sharingText = ["share-picker", "permission-probe", "share-permissions"].contains(windowType ?? "")
        let identityProof = identifier == "MeetingTopBarInfoButton" || identifier == "zm.meeting.window.main"
            || identifier?.hasPrefix("zm.meeting.window.leave") == true
        if name == kAXDescriptionAttribute && ["AXTextArea", "AXList"].contains(role ?? "") && sharingText
            && childrenRead && !(hasNonemptyURL ?? hasURL) && !presentationContent && !identityProof { return true }
        // Plain text and layout objects can advertise a description yet fail
        // its public single read. They do not identify actions or documents.
        // Keep the node and full subtree; never infer missing text as evidence.
        // Controls/rows/windows and all live document content stay strict: hiding
        // a label there could make ambiguous controls or page counters unique.
        let passiveRoles: Set<String> = ["AXTextArea", "AXStaticText", "AXUnknown", "AXGroup", "AXScrollArea", "AXSplitGroup", "AXImage"]
        return name == kAXDescriptionAttribute && role.map(passiveRoles.contains) == true
            && childrenRead && identityRead && (identifier ?? "").isEmpty && !hasURL && !presentationContent
    }
    static func permitsMissingAttribute(_ name: String, error: AXError) -> Bool {
        // A leaf normally has no AXChildren. AXRole, however, is required to select
        // controls safely. Communication errors are never evidence of an empty tree.
        if name == kAXRoleAttribute { return false }
        if error == .attributeUnsupported || error == .noValue { return true }
        return [.illegalArgument, .failure, .notImplemented].contains(error)
            && [kAXHelpAttribute, kAXValueAttribute, kAXIdentifierAttribute].contains(name)
    }
    static func permitsUnimplementedLeafChildren(role: String, singleError: AXError, countError: AXError) -> Bool {
        let leafRoles: Set<String> = ["AXStaticText", "AXImage", "AXButton", "AXCheckBox", "AXRadioButton", "AXMenuButton", "AXPopUpButton", "AXLink", "AXHeading", "AXTextField"]
        return leafRoles.contains(role) && [.failure, .notImplemented].contains(singleError) && [.failure, .notImplemented].contains(countError)
    }
    static func permitsClickFallback(_ error: AXError) -> Bool {
        [.actionUnsupported, .notImplemented, .failure].contains(error)
    }
    static func uncertainActionNeedsReadback(_ action: ZoomSlidesAXAction, error: AXError) -> Bool {
        guard error == .cannotComplete else { return false }
        switch action { case .press, .select: return true; default: return false }
    }
    static func permitsWindowReadRetry(_ error: AXError) -> Bool {
        [.cannotComplete, .failure, .notImplemented, .success].contains(error)
    }
    static func permitsSnapshotReadRetry(_ error: AXError) -> Bool { error == .cannotComplete || error == .invalidUIElement }
    static func singleReadOrder(_ names: [String]) -> [String] {
        var result = [kAXRoleAttribute]
        if names.contains(kAXChildrenAttribute) { result.append(kAXChildrenAttribute) }
        for name in names where !result.contains(name) { result.append(name) }
        return result
    }
    static func readContextLabel(windowType: String, node: Int, parentRole: String) -> String {
        let kinds = ["window-header", "main-meeting", "share-picker", "share-permissions", "permission-probe", "meeting-exit-dialog"]
        let kind = kinds.contains(windowType) ? windowType : "unknown"
        let role = parentRole.range(of: "^AX[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil ? parentRole : "unknown"
        return "windowType \(kind)，node \(max(0, min(node, 5000)))，parentRole \(role)"
    }
    static func hitTestDiagnostic(pid: pid_t?, bundle: String?, hitRole: String?, targetRole: String?) -> String {
        func role(_ value: String?) -> String { value.flatMap { $0.range(of: "^AX[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil ? $0 : nil } ?? "unknown" }
        let safeBundle = bundle.flatMap { $0.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$", options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
        return "hitPID \(pid.map(String.init) ?? "unknown")，hitBundle \(safeBundle)，hitRole \(role(hitRole))，targetRole \(role(targetRole))"
    }
    static func documentID(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              host == "slides.zoom.us" || host.hasSuffix(".slides.zoom.us") || host.range(of: "^[a-z0-9-]+slides\\.zoom\\.us$", options: .regularExpression) != nil,
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2, parts[0] == "p", !parts[1].isEmpty, parts[1].count <= 160,
              parts[1].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else { return nil }
        return parts[1]
    }
    /// Only explicitly labelled slide counters are eligible. Participant counts and bare numbers
    /// elsewhere in Zoom must never be mistaken for presentation progress.
    static func slideCounter(_ value: String) -> (current: Int, total: Int)? {
        let patterns = [#"(?i)^\s*slide\s+(\d+)\s*(?:of|/)\s*(\d+)\s*$"#,
                        #"^\s*第?\s*(\d+)\s*页\s*(?:/|，?\s*共)\s*(\d+)\s*页?\s*$"#]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern),
                  let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let a = Range(match.range(at: 1), in: value), let b = Range(match.range(at: 2), in: value),
                  let current = Int(value[a]), let total = Int(value[b]), current >= 1, current <= total, total <= 10000 else { continue }
            return (current, total)
        }
        return nil
    }
    static func slideshowCounter(_ value: String) -> (current: Int, total: Int)? {
        let prefix = "Zoom AI Slides Slideshow - "
        guard value.hasPrefix(prefix) else { return nil }
        return slideCounter("Slide " + value.dropFirst(prefix.count))
    }
    static func speakerCounter(_ value: String) -> (current: Int, total: Int)? {
        slideCounter("Slide " + value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func bindMeeting(_ state: ZoomSlidesAXState, title: String?, previous: ZoomSlidesBinding?) throws -> ZoomSlidesBinding {
        guard state.complete else { throw Failure.unavailable("Zoom 状态读取不完整，未执行操作。") }
        if let previous {
            guard state.pid == previous.pid, let window = state.windows.first(where: { $0.id == previous.meetingWindow }),
                  isMeeting(window), normalized(window.title) == normalized(previous.meetingTitle) else { throw Failure.meetingChanged }
            return previous
        }
        let meetings = state.windows.filter { isMeeting($0) && (title == nil || normalized($0.title) == normalized(title!)) }
        guard meetings.count == 1, let window = meetings.first else { throw Failure.ambiguousMeeting }
        return .init(pid: state.pid, meetingWindow: window.id, meetingTitle: window.title)
    }
    static func isMeeting(_ window: ZoomSlidesAXWindow) -> Bool {
        guard window.nodes.contains(where: { $0.identifier == "zm.meeting.window.main" }) else { return false }
        let controls = window.nodes.filter { $0.enabled && ["AXButton", "AXMenuButton", "AXCheckBox", "AXPopUpButton"].contains($0.role) }
        let leave = controls.contains { $0.named(["Leave", "Leave Meeting", "End", "End Meeting", "离开", "结束", "离开会议", "结束会议"]) }
        let microphone = controls.contains { node in node.text.contains { text in
            let value = normalized(text); return value.contains("mute") || value.contains("静音")
        } }
        let context = controls.contains { node in node.text.contains { text in
            let value = normalized(text); return ["participants", "参会者", "参与者", "share screen", "共享屏幕"].contains(where: value.contains)
        } }
        return leave && microphone && context
    }
    static func uniqueNode(in windows: [ZoomSlidesAXWindow], roles: Set<String>, names: [String]) throws -> ZoomSlidesAXNode {
        let matches = windows.flatMap(\.nodes).filter { $0.enabled && roles.contains($0.role) && $0.named(names) }
        guard matches.count == 1, let result = matches.first else { throw Failure.unavailable("无法唯一确认 Zoom 的目标控件，未执行操作。") }
        return result
    }
}

private final class ZoomSlidesCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    func token() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func cancel() { lock.lock(); generation &+= 1; lock.unlock() }
    func check(_ token: UInt64) throws {
        lock.lock(); let valid = generation == token; lock.unlock()
        if !valid || Task.isCancelled { throw ZoomSlidesDriver.Failure.cancelled }
    }
}

struct ZoomSlidesBinding: Equatable, Sendable { var pid: pid_t; var meetingWindow: String; var meetingTitle: String }
struct ZoomSlidesAXNode: Equatable, Sendable {
    var id: String
    var role: String
    var title = ""
    var description = ""
    var help = ""
    var value = ""
    var enabled = true
    var selected = false
    var url: String? = nil
    var identifier = ""
    var parentID: String? = nil
    var checked: Bool? = nil
    var text: [String] { [title, description, help, value].filter { !$0.isEmpty } }
    func named(_ names: [String]) -> Bool {
        let candidates = text.map(ZoomSlidesDriver.normalized)
        return names.contains { candidates.contains(ZoomSlidesDriver.normalized($0)) }
    }
}
struct ZoomSlidesAXWindow: Equatable, Sendable { var id: String; var title: String; var nodes: [ZoomSlidesAXNode] }
struct ZoomSlidesAXState: Equatable, Sendable { var pid: pid_t; var windows: [ZoomSlidesAXWindow]; var complete = true }
enum ZoomSlidesAXAction: Equatable, Sendable { case press(String), setValue(String, String), key(String, UInt16), select(String) }
protocol ZoomSlidesAXTransport: Sendable {
    func read(pid: pid_t?, deadline: Date, cancelled: () throws -> Void) throws -> ZoomSlidesAXState
    func perform(_ action: ZoomSlidesAXAction, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws
}

/// CFHash is only a bucket key: different AX objects may collide. Equality must
/// still be checked with CFEqual, including wrappers for the same remote object.
struct ZoomSlidesIdentitySet<Element> {
    private let hash: (Element) -> UInt
    private let equal: (Element, Element) -> Bool
    private var buckets: [UInt: [Element]] = [:]
    private(set) var count = 0
    init(hash: @escaping (Element) -> UInt, equal: @escaping (Element, Element) -> Bool) { self.hash = hash; self.equal = equal }
    mutating func insert(_ element: Element) -> Bool {
        let key = hash(element)
        if buckets[key]?.contains(where: { equal($0, element) }) == true { return false }
        buckets[key, default: []].append(element); count += 1
        return true
    }
}

struct ZoomSlidesSnapshotReadIssue: Error {
    var failure: ZoomSlidesDriver.Failure
    var code: AXError
}
enum ZoomSlidesSnapshotReader {
    /// Retry only reads, always rebuilding the whole snapshot. An operation that
    /// dispatched a button is outside this helper and can never be repeated here.
    static func read<Value>(deadline: Date, cancelled: () throws -> Void, operation: () throws -> Value) throws -> Value {
        for attempt in 0..<3 {
            try cancelled()
            guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("等待完整 Zoom 状态读回") }
            do { return try operation() }
            catch let issue as ZoomSlidesSnapshotReadIssue {
                guard ZoomSlidesDriver.permitsSnapshotReadRetry(issue.code) else { throw issue.failure }
                guard attempt < 2 else { throw ZoomSlidesDriver.Failure.unavailable("完整 Zoom 状态读取 3 次仍失败：" + issue.failure.localizedDescription) }
                try cancelled()
                guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("等待完整 Zoom 状态读回") }
                Thread.sleep(forTimeInterval: min(attempt == 0 ? 0.25 : 0.5, max(0, deadline.timeIntervalSinceNow)))
            }
        }
        throw ZoomSlidesDriver.Failure.unavailable("无法取得完整 Zoom 状态。")
    }
}

/// Injectable public AX reads. Fixture tests exercise the same batch decoding,
/// single-read recovery and window traversal without contacting another process.
struct ZoomSlidesAXReadClient {
    var multiple: (AXUIElement, [String]) -> (AXError, CFArray?)
    var single: (AXUIElement, String) -> (AXError, CFTypeRef?)
    var names: (AXUIElement) -> (AXError, CFArray?)
    var count: (AXUIElement, String) -> (AXError, CFIndex)
    var values: (AXUIElement, String, CFIndex) -> (AXError, CFArray?)
    var timeout: (AXUIElement, Float) -> Void
    static let system = ZoomSlidesAXReadClient(
        multiple: { element, names in
            var raw: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
            return (error, raw)
        }, single: { element, name in
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            return (error, raw)
        }, names: { element in
            var raw: CFArray?
            let error = AXUIElementCopyAttributeNames(element, &raw)
            return (error, raw)
        }, count: { element, name in
            var count: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
            return (error, count)
        }, values: { element, name, count in
            var raw: CFArray?
            let error = AXUIElementCopyAttributeValues(element, name as CFString, 0, count, &raw)
            return (error, raw)
        }, timeout: { element, timeout in _ = AXUIElementSetMessagingTimeout(element, timeout) })
}

/// AX handles are retained only for the most recent snapshot. The driver selects semantic nodes
/// from that snapshot; it never treats a fixed child index as a stable application control.
final class ZoomSlidesSystemAXTransport: ZoomSlidesAXTransport, @unchecked Sendable {
    private let includeExitDialogs: Bool
    private let readClient: ZoomSlidesAXReadClient
    init(includeExitDialogs: Bool = false, readClient: ZoomSlidesAXReadClient = .system) {
        self.includeExitDialogs = includeExitDialogs; self.readClient = readClient
    }
    private struct ReadContext {
        var windowType: String
        var node: Int
        var parentRole: String
        var deadline: Date
        var cancelled: () throws -> Void
        var presentationContent = false
        var label: String { ZoomSlidesDriver.readContextLabel(windowType: windowType, node: node, parentRole: parentRole) }
        func check(_ element: AXUIElement, client: ZoomSlidesAXReadClient) throws {
            try cancelled()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ZoomSlidesDriver.Failure.timedOut("读取 Zoom 状态（\(label)）") }
            client.timeout(element, Float(min(0.2, remaining)))
        }
    }
    private var handles: [String: AXUIElement] = [:]
    private var windowHandles: [(String, AXUIElement)] = []
    func read(pid: pid_t?, deadline: Date, cancelled: () throws -> Void) throws -> ZoomSlidesAXState {
        var complete = false
        defer { if !complete { handles.removeAll() } }
        let result = try withoutActuallyEscaping(cancelled) { check in
            try ZoomSlidesSnapshotReader.read(deadline: deadline, cancelled: check) {
                handles.removeAll()
                return try readOnce(pid: pid, deadline: deadline, cancelled: check)
            }
        }
        complete = true
        return result
    }
    private func readOnce(pid: pid_t?, deadline: Date, cancelled: @escaping () throws -> Void) throws -> ZoomSlidesAXState {
        try cancelled()
        guard AXIsProcessTrusted() else { throw ZoomSlidesDriver.Failure.permissionRequired }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").filter { !$0.isTerminated }
        guard let app = pid.flatMap({ wanted in apps.first { $0.processIdentifier == wanted } }) ?? (pid == nil && apps.count == 1 ? apps.first : nil) else {
            throw pid == nil ? ZoomSlidesDriver.Failure.zoomNotRunning : ZoomSlidesDriver.Failure.meetingChanged
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.7)
        let windows = try readWindows(root, deadline: deadline, cancelled: cancelled)
        return try collectWindows(windows, pid: app.processIdentifier, deadline: deadline, cancelled: cancelled)
    }
    /// Production and fixture snapshots share this complete traversal. Failed
    /// collections discard handles so partially read nodes can never be acted on.
    func collectWindows(_ windows: [AXUIElement], pid: pid_t, deadline: Date, cancelled: @escaping () throws -> Void) throws -> ZoomSlidesAXState {
        handles.removeAll()
        var complete = false
        defer { if !complete { handles.removeAll() } }
        var result: [ZoomSlidesAXWindow] = [], surviving: [(String, AXUIElement)] = []
        var uniqueNodes = identitySet()
        for (windowIndex, window) in windows.enumerated() {
            try cancelled()
            guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("读取 Zoom 状态") }
            let id = windowHandles.first(where: { CFEqual($0.1, window) })?.0 ?? UUID().uuidString
            surviving.append((id, window))
            readClient.timeout(window, Float(min(0.2, max(0.01, deadline.timeIntervalSinceNow))))
            let header = try attributes(window, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute], context: .init(windowType: "window-header", node: windowIndex + 1, parentRole: "unknown", deadline: deadline, cancelled: cancelled))
            let windowTitle = header[kAXTitleAttribute] as? String ?? ""
            let windowDescription = header[kAXDescriptionAttribute] as? String ?? ""
            let windowIdentifier = header[kAXIdentifierAttribute] as? String ?? ""
            // Empty-title popovers (My Notes, Meeting info, etc.) are not presentation
            // controls. Probe for the known permission question before traversing them.
            var kind = ZoomSlidesDriver.windowKind(title: windowTitle, description: windowDescription, identifier: windowIdentifier, includeExitDialogs: includeExitDialogs)
            if kind == nil && windowTitle.isEmpty {
                if try permissionPrompt(in: window, deadline: deadline, cancelled: cancelled, uniqueNodes: &uniqueNodes) { kind = "share-permissions" }
            }
            guard let windowType = kind else { continue }
            var queue = [window], parents: [String?] = [nil], cursor = 0, nodes: [ZoomSlidesAXNode] = []
            var roles: [String: String] = [:], presentationNodes = Set<String>()
            var seen = identitySet(); _ = seen.insert(window)
            try register(window, in: &uniqueNodes, windowType: windowType, deadline: deadline, cancelled: cancelled)
            while cursor < queue.count {
                try cancelled()
                guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("读取 Zoom 控件") }
                let element = queue[cursor], parent = parents[cursor]; cursor += 1
                readClient.timeout(element, Float(min(0.2, max(0.01, deadline.timeIntervalSinceNow))))
                let nodeID = UUID().uuidString
                handles[nodeID] = element
                let values = try attributes(element, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute,
                    kAXEnabledAttribute, kAXSelectedAttribute, kAXURLAttribute, kAXIdentifierAttribute, kAXChildrenAttribute],
                    context: .init(windowType: windowType, node: cursor, parentRole: parent.flatMap { roles[$0] } ?? "unknown", deadline: deadline, cancelled: cancelled,
                                   presentationContent: parent.map(presentationNodes.contains) ?? false))
                let raw = values[kAXValueAttribute], rawURL = values[kAXURLAttribute]
                roles[nodeID] = values[kAXRoleAttribute] as? String ?? "unknown"
                if roles[nodeID] == "AXWebArea" || parent.map(presentationNodes.contains) == true { presentationNodes.insert(nodeID) }
                nodes.append(ZoomSlidesAXNode(id: nodeID, role: values[kAXRoleAttribute] as? String ?? "",
                    title: values[kAXTitleAttribute] as? String ?? "", description: values[kAXDescriptionAttribute] as? String ?? "",
                    help: values[kAXHelpAttribute] as? String ?? "", value: raw as? String ?? "",
                    enabled: (values[kAXEnabledAttribute] as? Bool) != false,
                    selected: (values[kAXSelectedAttribute] as? Bool) == true || (raw as? NSNumber)?.intValue == 1,
                    url: (rawURL as? URL)?.absoluteString ?? (rawURL as? String),
                    identifier: values[kAXIdentifierAttribute] as? String ?? "", parentID: parent,
                    checked: (raw as? NSNumber).flatMap { [0, 1].contains($0.intValue) ? $0.boolValue : nil }))
                let descendants = values[kAXChildrenAttribute] as? [AXUIElement] ?? []
                for child in descendants where seen.insert(child) {
                    try register(child, in: &uniqueNodes, windowType: windowType, deadline: deadline, cancelled: cancelled)
                    queue.append(child); parents.append(nodeID)
                }
            }
            result.append(.init(id: id, title: windowTitle, nodes: nodes))
        }
        windowHandles = surviving
        complete = true
        return .init(pid: pid, windows: result, complete: true)
    }
    func perform(_ action: ZoomSlidesAXAction, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws {
        try cancelled()
        guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("执行 Zoom 操作") }
        guard NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "us.zoom.xos" else { throw ZoomSlidesDriver.Failure.meetingChanged }
        let id: String
        switch action { case .press(let token), .setValue(let token, _), .key(let token, _), .select(let token): id = token }
        guard let element = handles[id] else { throw ZoomSlidesDriver.Failure.unavailable("Zoom 控件状态已过期。") }
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid else { throw ZoomSlidesDriver.Failure.meetingChanged }
        try cancelled()
        guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("执行 Zoom 控件操作") }
        AXUIElementSetMessagingTimeout(element, Float(min(0.3, max(0.01, deadline.timeIntervalSinceNow))))
        let result: AXError
        let actionName: String
        switch action {
        case .press: actionName = "AXPress"; result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case .setValue(_, let value): actionName = "AXSetValue"; result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
        case .select:
            actionName = "AXSelect"
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(element, kAXSelectedAttribute as CFString, &settable) == .success && settable.boolValue {
                result = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            } else { result = AXUIElementPerformAction(element, kAXPressAction as CFString) }
        case .key(_, let code):
            actionName = "TabKey"
            guard code == 123 || code == 124 else { throw ZoomSlidesDriver.Failure.unavailable("只允许在已绑定的共享选择器中切换标签。") }
            _ = try activateWindow(for: element, pid: pid, deadline: deadline, cancelled: cancelled)
            let focusError = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if focusError != .success && focusError != .attributeUnsupported && !ZoomSlidesDriver.permitsClickFallback(focusError) { throw actionFailure("AXFocused", focusError) }
            let root = AXUIElementCreateApplication(pid)
            var focused = attribute(root, kAXFocusedUIElementAttribute)
            var focusVerified = false
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() { focusVerified = try isTargetOrDescendant(focused as! AXUIElement, of: element, pid: pid, deadline: deadline, cancelled: cancelled) }
            if !focusVerified {
                let before = attribute(element, kAXValueAttribute) as? String
                try click(element, pid: pid, deadline: deadline, cancelled: cancelled)
                // A segmented tab control can select Files on click. Let the caller
                // read that result instead of sending an extra arrow past it.
                let after = attribute(element, kAXValueAttribute) as? String
                if before != nil && after != nil && before != after { handles.removeAll(); return }
                focused = attribute(root, kAXFocusedUIElementAttribute)
            }
            guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), try isTargetOrDescendant(focused as! AXUIElement, of: element, pid: pid, deadline: deadline, cancelled: cancelled),
                  let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw ZoomSlidesDriver.Failure.unavailable("共享选择器真实焦点不符，未发送按键。") }
            try cancelled(); guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("确认共享标签焦点") }
            down.postToPid(pid); up.postToPid(pid)
            result = .success
        }
        if result != .success {
            if ZoomSlidesDriver.uncertainActionNeedsReadback(action, error: result) {
                // A custom Zoom button can open a modal before AXPress replies,
                // producing cannotComplete despite the transition having happened.
                // This only acknowledges dispatch: the caller must read the actual
                // next state, never repeat this action or count it as UI success.
                handles.removeAll()
                try cancelled()
                return
            }
            let eligible: Bool
            switch action { case .press, .select: eligible = ZoomSlidesDriver.permitsClickFallback(result); default: eligible = false }
            guard eligible else { throw actionFailure(actionName, result) }
            do { try click(element, pid: pid, deadline: deadline, cancelled: cancelled) }
            catch ZoomSlidesDriver.Failure.cancelled { throw ZoomSlidesDriver.Failure.cancelled }
            catch let error as ZoomSlidesDriver.Failure {
                if case .timedOut = error { throw error }
                throw actionFailure(actionName, result, detail: error.localizedDescription)
            }
        }
        handles.removeAll()
    }
    private func actionFailure(_ action: String, _ error: AXError, detail: String = "未执行不确定的控件操作。") -> ZoomSlidesDriver.Failure {
        .unavailable("Zoom 操作失败（\(action)，AXError \(error.rawValue)）：" + detail)
    }
    private func activateWindow(for element: AXUIElement, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws -> AXUIElement {
        try cancelled()
        guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("激活目标 Zoom 窗口") }
        guard let app = NSRunningApplication(processIdentifier: pid), app.bundleIdentifier == "us.zoom.xos", !app.isTerminated,
              let rawWindow = attribute(element, kAXWindowAttribute), CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { throw ZoomSlidesDriver.Failure.meetingChanged }
        let window = rawWindow as! AXUIElement
        var windowPID: pid_t = 0
        guard AXUIElementGetPid(window, &windowPID) == .success, windowPID == pid else { throw ZoomSlidesDriver.Failure.meetingChanged }
        guard app.activate(options: []) else { throw actionFailure("activate", .failure) }
        try cancelled(); guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("激活目标 Zoom 窗口") }
        let raise = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if raise != .success && !ZoomSlidesDriver.permitsClickFallback(raise) { throw actionFailure("AXRaise", raise) }
        let focusDeadline = min(deadline, Date().addingTimeInterval(1))
        let root = AXUIElementCreateApplication(pid)
        while Date() < focusDeadline {
            try cancelled()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               let focused = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, window) { return window }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw actionFailure("AXRaise/focus", raise == .success ? .failure : raise)
    }
    private func click(_ element: AXUIElement, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws {
        let window = try activateWindow(for: element, pid: pid, deadline: deadline, cancelled: cancelled)
        try cancelled()
        guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("确认 Zoom 点击目标") }
        guard CGPreflightPostEventAccess() else { throw ZoomSlidesDriver.Failure.permissionRequired }
        let bounds = try elementBounds(element), windowBounds = try elementBounds(window)
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        guard point.x.isFinite, point.y.isFinite, windowBounds.contains(point) else { throw actionFailure("clickBounds", .illegalArgument) }
        var hit: AXUIElement?
        let system = AXUIElementCreateSystemWide(); AXUIElementSetMessagingTimeout(system, 0.15)
        let hitError = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard hitError == .success, let hit, try isTargetOrDescendant(hit, of: element, pid: pid, deadline: deadline, cancelled: cancelled) else {
            throw actionFailure("AXHitTest", hitError == .success ? .failure : hitError,
                detail: try hitTestDiagnostic(hit: hit, target: element, deadline: deadline, cancelled: cancelled))
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw actionFailure("mouseEvents", .failure) }
        try cancelled(); guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("发送 Zoom 点击") }
        down.setIntegerValueField(.mouseEventClickState, value: 1); up.setIntegerValueField(.mouseEventClickState, value: 1)
        // Release immediately even if cancellation arrives between the pair.
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        try cancelled()
    }
    private func hitTestDiagnostic(hit: AXUIElement?, target: AXUIElement, deadline: Date, cancelled: () throws -> Void) throws -> String {
        try cancelled()
        var actualPID: pid_t?
        if let hit {
            var value: pid_t = 0
            if AXUIElementGetPid(hit, &value) == .success { actualPID = value }
        }
        func readRole(_ element: AXUIElement?) throws -> String? {
            try cancelled()
            guard let element, Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.05, deadline.timeIntervalSinceNow)))
            return attribute(element, kAXRoleAttribute) as? String
        }
        let bundle = actualPID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
        return ZoomSlidesDriver.hitTestDiagnostic(pid: actualPID, bundle: bundle,
            hitRole: try readRole(hit), targetRole: try readRole(target))
    }
    private func elementBounds(_ element: AXUIElement) throws -> CGRect {
        guard let rawPoint = attribute(element, kAXPositionAttribute), CFGetTypeID(rawPoint) == AXValueGetTypeID(),
              let rawSize = attribute(element, kAXSizeAttribute), CFGetTypeID(rawSize) == AXValueGetTypeID() else { throw actionFailure("AXPosition/AXSize", .noValue) }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPoint as! AXValue, .cgPoint, &point), AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { throw actionFailure("AXPosition/AXSize", .illegalArgument) }
        return CGRect(origin: point, size: size)
    }
    private func isTargetOrDescendant(_ element: AXUIElement, of target: AXUIElement, pid: pid_t, deadline: Date, cancelled: () throws -> Void) throws -> Bool {
        var current: AXUIElement? = element, seen = identitySet(), depth = 0
        while let node = current, seen.insert(node), depth < 40 {
            try cancelled(); guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("核对 Zoom 控件身份") }
            var actual: pid_t = 0
            guard AXUIElementGetPid(node, &actual) == .success, actual == pid else { return false }
            if CFEqual(node, target) { return true }
            depth += 1
            guard let parent = attribute(node, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            current = (parent as! AXUIElement)
        }
        return false
    }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func readWindows(_ root: AXUIElement, deadline: Date, cancelled: () throws -> Void) throws -> [AXUIElement] {
        let retryDeadline = min(deadline, Date().addingTimeInterval(2))
        var lastError = AXError.failure, lastType = "nil", auxiliary = ""
        for attempt in 0..<3 {
            try cancelled()
            guard Date() < retryDeadline else { break }
            AXUIElementSetMessagingTimeout(root, Float(min(0.7, max(0.01, retryDeadline.timeIntervalSinceNow))))
            var raw: CFTypeRef?
            lastError = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &raw)
            lastType = raw.map { CFGetTypeID($0) == CFArrayGetTypeID() ? "CFArray" : "CFTypeID \(CFGetTypeID($0))" } ?? "nil"
            if lastError == .success, let windows = raw as? [AXUIElement], !windows.isEmpty || attempt == 2 { return windows }
            guard ZoomSlidesDriver.permitsWindowReadRetry(lastError) else { break }
            // Some modal transitions reject CopyAttributeValue while the public
            // array APIs still expose an authoritative list. Never infer a window.
            try cancelled()
            guard Date() < retryDeadline else { break }
            AXUIElementSetMessagingTimeout(root, Float(min(0.7, max(0.01, retryDeadline.timeIntervalSinceNow))))
            var count: CFIndex = 0
            let countError = AXUIElementGetAttributeValueCount(root, kAXWindowsAttribute as CFString, &count)
            auxiliary = ", count AXError \(countError.rawValue)"
            if countError == .success && count >= 0 && count <= 64 {
                if count == 0 && attempt == 2 { return [] }
                if count > 0 {
                    try cancelled()
                    guard Date() < retryDeadline else { break }
                    AXUIElementSetMessagingTimeout(root, Float(min(0.7, max(0.01, retryDeadline.timeIntervalSinceNow))))
                    var values: CFArray?
                    let copyError = AXUIElementCopyAttributeValues(root, kAXWindowsAttribute as CFString, 0, count, &values)
                    auxiliary += ", array AXError \(copyError.rawValue)"
                    if copyError == .success, let windows = values as? [AXUIElement], windows.count == count { return windows }
                    if !ZoomSlidesDriver.permitsWindowReadRetry(copyError) && copyError != .attributeUnsupported { throw windowReadFailure(copyError, valueType: values == nil ? "nil" : "CFArray", auxiliary: auxiliary) }
                }
            } else if countError != .success && !ZoomSlidesDriver.permitsWindowReadRetry(countError) && countError != .attributeUnsupported {
                throw windowReadFailure(countError, valueType: lastType, auxiliary: auxiliary)
            }
            if attempt < 2 { try cancelled(); Thread.sleep(forTimeInterval: min(0.05, max(0, retryDeadline.timeIntervalSinceNow))) }
        }
        throw windowReadFailure(lastError, valueType: lastType, auxiliary: auxiliary)
    }
    private func windowReadFailure(_ error: AXError, valueType: String, auxiliary: String) -> ZoomSlidesSnapshotReadIssue {
        .init(failure: .unavailable("Zoom 窗口读取失败（AXWindows，AXError \(error.rawValue)，值类型 \(valueType)\(auxiliary)），未执行操作。"), code: error)
    }
    /// One public AX IPC per node, including children; unsupported optional fields are absent.
    /// Communication errors are not treated as an empty successful accessibility tree.
    private func attributes(_ element: AXUIElement, _ names: [String], context: ReadContext) throws -> [String: Any] {
        try context.check(element, client: readClient)
        let (batchError, raw) = readClient.multiple(element, names)
        var order = ZoomSlidesDriver.singleReadOrder(names)
        // Read required structure and semantic fields before supplemental text,
        // consistently in both the batch and single-read fallback paths.
        if order.contains(kAXDescriptionAttribute) {
            order.removeAll { $0 == kAXDescriptionAttribute }; order.append(kAXDescriptionAttribute)
        }
        var result: [String: Any] = [:], resolved = Set<String>()
        func readSingle(_ name: String) throws {
            let value = try retryAttribute(element, name, known: result, resolved: resolved, context: context)
            if let raw = value.value { result[name] = raw }
            if value.resolved { resolved.insert(name) }
        }
        if batchError == .cannotComplete {
            for name in order { try readSingle(name) }
            return result
        }
        guard batchError == .success, let values = raw as? [Any], values.count == names.count else {
            throw attributeFailure("AXMultipleAttributes", batchError == .success ? .failure : batchError, context: context)
        }
        let fields = Dictionary(uniqueKeysWithValues: zip(names, values))
        for name in order {
            guard let value = fields[name] else { try readSingle(name); continue }
            if CFGetTypeID(value as CFTypeRef) == CFNullGetTypeID() {
                if name == kAXRoleAttribute { try readSingle(name) }
                else { resolved.insert(name) }
                continue
            }
            if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
                let axValue = value as! AXValue
                if AXValueGetType(axValue) == .axError {
                    // A successful batch can contain a per-field AX error. Its
                    // public single read may still succeed; retry only that field.
                    try readSingle(name)
                    continue
                }
            }
            if name == kAXRoleAttribute && (value as? String)?.isEmpty != false { throw attributeFailure(name, .noValue, context: context) }
            if name == kAXChildrenAttribute && !(value is [AXUIElement]) { throw attributeFailure(name, .illegalArgument, role: result[kAXRoleAttribute] as? String, context: context) }
            if name == kAXIdentifierAttribute && !(value is String) { throw attributeFailure(name, .illegalArgument, role: result[kAXRoleAttribute] as? String, context: context) }
            result[name] = value; resolved.insert(name)
        }
        return result
    }
    private struct AttributeRead {
        var value: Any?
        // Standard absence proves no value; a tolerated generic metadata failure
        // does not prove that an object has no identity or child structure.
        var resolved: Bool
    }
    private func retryAttribute(_ element: AXUIElement, _ name: String, known: [String: Any] = [:], resolved: Set<String> = [], context: ReadContext) throws -> AttributeRead {
        try context.check(element, client: readClient)
        let role = known[kAXRoleAttribute] as? String
        let (code, raw) = readClient.single(element, name)
        let error: AXError = code == .success && raw == nil ? .noValue : code
        if error != .success {
            if name == kAXChildrenAttribute && [.failure, .notImplemented].contains(error) {
                return .init(value: try recoverChildren(element, singleError: error, knownRole: role, context: context), resolved: true)
            }
            if [kAXTitleAttribute, kAXDescriptionAttribute].contains(name), [.failure, .notImplemented, .illegalArgument].contains(error) {
                let supported = try supportedAttributeNames(element, role: role, context: context)
                // Both profiles can encounter unrelated share/help popovers.
                // Only the named sharing/probe contexts permit supplemental
                // text recovery; real exit-dialog/identity/action text stays strict.
                if ZoomSlidesDriver.permitsMissingDescriptor(name, error: error, role: role, supportedAttributes: supported,
                    childrenRead: resolved.contains(kAXChildrenAttribute), identityRead: resolved.contains(kAXIdentifierAttribute) && resolved.contains(kAXURLAttribute),
                    identifier: known[kAXIdentifierAttribute] as? String, hasURL: known[kAXURLAttribute] != nil,
                    presentationContent: context.presentationContent || role == "AXWebArea", windowType: context.windowType,
                    hasNonemptyURL: known[kAXURLAttribute].map { ($0 as? String)?.isEmpty != true }) { return .init(value: nil, resolved: false) }
            }
            guard ZoomSlidesDriver.permitsMissingAttribute(name, error: error) else { throw attributeFailure(name, error, role: role, context: context) }
            return .init(value: nil, resolved: error == .attributeUnsupported || error == .noValue)
        }
        guard let value = raw else { throw attributeFailure(name, .noValue, context: context) }
        if CFGetTypeID(value) == CFNullGetTypeID() {
            guard ZoomSlidesDriver.permitsMissingAttribute(name, error: .noValue) else { throw attributeFailure(name, .noValue, context: context) }
            return .init(value: nil, resolved: true)
        }
        if name == kAXRoleAttribute && (value as? String)?.isEmpty != false { throw attributeFailure(name, .noValue, context: context) }
        if name == kAXChildrenAttribute && !(value is [AXUIElement]) { throw attributeFailure(name, .illegalArgument, role: role, context: context) }
        if name == kAXIdentifierAttribute && !(value is String) { throw attributeFailure(name, .illegalArgument, role: role, context: context) }
        return .init(value: value, resolved: true)
    }
    private func supportedAttributeNames(_ element: AXUIElement, role: String?, context: ReadContext) throws -> [String]? {
        try context.check(element, client: readClient)
        let (error, raw) = readClient.names(element)
        if error == .success {
            guard let names = raw as? [String] else { throw attributeFailure("AXAttributeNames", .failure, role: role, context: context) }
            return names
        }
        // A failed metadata query does not prove a primary title absent.
        if [.attributeUnsupported, .noValue, .notImplemented, .failure].contains(error) { return nil }
        throw attributeFailure("AXAttributeNames", error, role: role, context: context)
    }
    private func recoverChildren(_ element: AXUIElement, singleError: AXError, knownRole: String?, context: ReadContext) throws -> [AXUIElement] {
        let role: String
        if let knownRole { role = knownRole }
        else {
            guard let value = try retryAttribute(element, kAXRoleAttribute, context: context).value as? String, !value.isEmpty else { throw attributeFailure(kAXRoleAttribute, .noValue, context: context) }
            role = value
        }
        try context.check(element, client: readClient)
        let (countError, count) = readClient.count(element, kAXChildrenAttribute)
        if countError == .success {
            if count == 0 { return [] }
            guard count > 0 && count <= 5000 else { throw attributeFailure(kAXChildrenAttribute, .failure, role: role, context: context) }
            try context.check(element, client: readClient)
            let (copyError, children) = readClient.values(element, kAXChildrenAttribute, count)
            guard copyError == .success, let values = children as? [AXUIElement], values.count == count else {
                throw attributeFailure(kAXChildrenAttribute, copyError == .success ? .failure : copyError, role: role, context: context)
            }
            return values
        }
        guard ZoomSlidesDriver.permitsUnimplementedLeafChildren(role: role, singleError: singleError, countError: countError) else { throw attributeFailure(kAXChildrenAttribute, countError, role: role, context: context) }
        return []
    }
    private func attributeFailure(_ name: String, _ error: AXError, role: String? = nil, context: ReadContext? = nil) -> ZoomSlidesSnapshotReadIssue {
        let safeRole = role.flatMap { $0.range(of: "^AX[A-Za-z0-9]{1,64}$", options: .regularExpression) != nil ? $0 : nil } ?? "unknown"
        let location = context.map { "，" + $0.label } ?? ""
        return .init(failure: .unavailable("Zoom 控件读取失败（\(name)，role \(safeRole)，AXError \(error.rawValue)\(location)），未执行操作。"), code: error)
    }
    private func identitySet() -> ZoomSlidesIdentitySet<AXUIElement> {
        ZoomSlidesIdentitySet(hash: { CFHash($0) }, equal: { CFEqual($0, $1) })
    }
    private func register(_ element: AXUIElement, in seen: inout ZoomSlidesIdentitySet<AXUIElement>, windowType: String, deadline: Date, cancelled: () throws -> Void) throws {
        try cancelled()
        guard Date() < deadline else { throw ZoomSlidesDriver.Failure.timedOut("读取 Zoom 状态（窗口 \(windowType)）") }
        if seen.insert(element) && seen.count > 5000 {
            throw ZoomSlidesDriver.Failure.unavailable("Zoom 状态达到唯一节点上限（5000，窗口 \(windowType)），未执行操作。")
        }
    }
    private func permissionPrompt(in window: AXUIElement, deadline: Date, cancelled: @escaping () throws -> Void, uniqueNodes: inout ZoomSlidesIdentitySet<AXUIElement>) throws -> Bool {
        var queue = [window], cursor = 0
        var parentRoles = ["unknown"], presentationNodes = [false]
        var seen = identitySet(); _ = seen.insert(window)
        try register(window, in: &uniqueNodes, windowType: "permission-probe", deadline: deadline, cancelled: cancelled)
        let probeDeadline = min(deadline, Date().addingTimeInterval(2))
        while cursor < queue.count {
            try cancelled()
            guard Date() < probeDeadline else { return false }
            let element = queue[cursor], parentRole = parentRoles[cursor]; cursor += 1
            readClient.timeout(element, Float(min(0.2, max(0.01, probeDeadline.timeIntervalSinceNow))))
            let values = try attributes(element, [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXChildrenAttribute, kAXIdentifierAttribute, kAXURLAttribute], context: .init(windowType: "permission-probe", node: cursor, parentRole: parentRole, deadline: probeDeadline, cancelled: cancelled, presentationContent: presentationNodes[cursor - 1]))
            if [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap({ values[$0] as? String }).contains(where: { ZoomSlidesDriver.normalized($0) == "how do you want to share?" }) { return true }
            for child in values[kAXChildrenAttribute] as? [AXUIElement] ?? [] where seen.insert(child) {
                try register(child, in: &uniqueNodes, windowType: "permission-probe", deadline: deadline, cancelled: cancelled)
                queue.append(child)
                parentRoles.append(values[kAXRoleAttribute] as? String ?? "unknown")
                presentationNodes.append(presentationNodes[cursor - 1] || values[kAXRoleAttribute] as? String == "AXWebArea")
            }
        }
        return false
    }
}
