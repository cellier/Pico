import AppKit
import ApplicationServices

enum MeetingSignal { case joined, absent, ended, unknown }
struct MeetingObservation {
    var signal: MeetingSignal
    var pid: pid_t = 0
    var title = "Zoom meeting"
}
/// Silence alone never ends a meeting. Inaccessible UI is unknown, not absent.
struct MeetingDebouncer {
    private(set) var active = false
    private var since: Date?
    private var candidate: MeetingSignal?
    private(set) var transitionTime: Date?
    mutating func update(_ signal: MeetingSignal, at now: Date, remoteAudioRecently: Bool) -> Bool? {
        if signal == .unknown { since = nil; candidate = nil; return nil }
        let positive = signal == .joined
        if positive == active || (!positive && signal != .ended && remoteAudioRecently) { since = nil; return nil }
        if since == nil || candidate != signal { since = now; candidate = signal }
        if now.timeIntervalSince(since!) >= (positive ? 4 : signal == .ended ? 8 : 30) {
            transitionTime = since; active = positive; since = nil; candidate = nil; return positive
        }
        return nil
    }
    mutating func reset() { active = false; since = nil; candidate = nil; transitionTime = nil }
}
protocol MeetingDetecting { func observe() -> MeetingObservation }
struct ZoomMeetingAdapter: MeetingDetecting {
    func observe() -> MeetingObservation {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "us.zoom.xos").first else { return .init(signal: .absent) }
        guard AXIsProcessTrusted() else { return .init(signal: .unknown) }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] else { return .init(signal: .unknown) }
        var snapshots: [[String]] = []
        var incomplete = false
        for window in windows {
            let title = attribute(window, kAXTitleAttribute) as? String ?? "Zoom meeting"
            let minimized = attribute(window, kAXMinimizedAttribute) as? Bool ?? false
            if minimized && (title.lowercased().contains("meeting") || title.contains("会议")) { incomplete = true }
            var queue = [window], texts: [String] = [], count = 0
            var next = 0
            let deadline = Date().addingTimeInterval(1.5)
            while next < queue.count && count < 1000 && Date() < deadline {
                let element = queue[next]; next += 1; count += 1
                let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                if ["AXButton", "AXMenuButton", "AXCheckBox", "AXPopUpButton"].contains(role), (attribute(element, kAXEnabledAttribute) as? Bool) != false {
                    texts.append(contentsOf: [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(element, $0) as? String }.map { $0.lowercased() })
                }
                var children: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
                if result == .success { queue.append(contentsOf: children as? [AXUIElement] ?? []) }
                else if result != .attributeUnsupported && result != .noValue { incomplete = true }
            }
            if Self.isJoined(controls: texts) { return .init(signal: .joined, pid: app.processIdentifier, title: title) }
            snapshots.append(texts)
            if next < queue.count { incomplete = true }
        }
        return .init(signal: Self.classify(controlsByWindow: snapshots, incomplete: incomplete), pid: app.processIdentifier)
    }
    static func classify(controlsByWindow: [[String]], incomplete: Bool) -> MeetingSignal {
        if controlsByWindow.contains(where: isJoined) { return .joined }
        if incomplete { return .unknown }
        if controlsByWindow.contains(where: { controls in
            let text = controls.joined(separator: "\n").lowercased()
            return ["participants", "参会者", "参与者", "share screen", "共享屏幕"].contains(where: { text.contains($0) })
                && ["mute", "静音"].contains(where: { text.contains($0) })
        }) { return .unknown } // Meeting toolbar can be partially hidden.
        // A readable Zoom home screen is an explicit exit signal, even if Zoom
        // keeps running or plays audio. Window titles alone are not meeting evidence.
        if controlsByWindow.contains(where: { controls in
            let text = controls.joined(separator: "\n").lowercased()
            let newMeeting = ["new meeting", "新会议", "发起会议"].contains { text.contains($0) }
            let join = ["join", "加入"].contains { text.contains($0) }
            return newMeeting && join
        }) { return .ended }
        return .absent
    }
    static func isJoined(controls: [String]) -> Bool {
        let all = controls.joined(separator: "\n").lowercased()
        let leave = ["leave meeting", "end meeting", "离开会议", "结束会议", "leave"].contains { all.contains($0) }
            || controls.contains { ["结束", "离开", "end"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
        let mic = ["mute", "unmute", "静音"].contains { all.contains($0) }
        // Video+mute+leave can also appear in a preview/waiting room.
        let context = ["participants", "参会者", "参与者", "share screen", "共享屏幕"].contains { all.contains($0) }
        return leave && mic && context
    }
    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
}
