import AppKit
import ApplicationServices

enum MeetingSignal { case joined, absent, unknown }
struct MeetingObservation {
    var signal: MeetingSignal
    var pid: pid_t = 0
    var title = "Zoom meeting"
}
/// Silence alone never ends a meeting. Inaccessible UI is unknown, not absent.
struct MeetingDebouncer {
    private(set) var active = false
    private var since: Date?
    mutating func update(_ signal: MeetingSignal, at now: Date, remoteAudioRecently: Bool) -> Bool? {
        if signal == .unknown { since = nil; return nil }
        let positive = signal == .joined
        if positive == active || (!positive && remoteAudioRecently) { since = nil; return nil }
        if since == nil { since = now }
        if now.timeIntervalSince(since!) >= (positive ? 4 : 30) {
            active = positive; since = nil; return positive
        }
        return nil
    }
    mutating func reset() { active = false; since = nil }
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
        var hasMeetingWindow = false
        var incomplete = false
        for window in windows {
            let title = attribute(window, kAXTitleAttribute) as? String ?? "Zoom meeting"
            let lowered = title.lowercased()
            hasMeetingWindow = hasMeetingWindow || lowered.contains("meeting") || lowered.contains("会议")
            var queue = [window], texts: [String] = [], count = 0
            var next = 0
            let deadline = Date().addingTimeInterval(1.5)
            while next < queue.count && count < 1000 && Date() < deadline {
                let element = queue[next]; next += 1; count += 1
                let role = attribute(element, kAXRoleAttribute) as? String ?? ""
                if ["AXButton", "AXMenuButton", "AXCheckBox", "AXPopUpButton"].contains(role), (attribute(element, kAXEnabledAttribute) as? Bool) != false {
                    texts.append(contentsOf: [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].compactMap { attribute(element, $0) as? String }.map { $0.lowercased() })
                }
                queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
            }
            if Self.isJoined(controls: texts) { return .init(signal: .joined, pid: app.processIdentifier, title: title) }
            if next < queue.count { incomplete = true }
        }
        return .init(signal: (hasMeetingWindow || incomplete) ? .unknown : .absent, pid: app.processIdentifier)
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
