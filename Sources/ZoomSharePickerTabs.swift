import Foundation

/// Resolves only the Files tab in an already bound Zoom share picker. The legacy
/// segmented control and the four-tab radio layout expose different AX semantics.
enum ZoomSharePickerTabs {
    static func filesAction(in window: ZoomSlidesAXWindow) throws -> ZoomSlidesAXAction? {
        guard Set(window.nodes.map(\.id)).count == window.nodes.count else { throw unsupported() }
        let byID = Dictionary(uniqueKeysWithValues: window.nodes.map { ($0.id, $0) })
        let legacy = window.nodes.filter {
            $0.enabled && $0.named(["Switch"]) && ["AXTabGroup", "AXTabControl", "AXRadioGroup", "AXButton"].contains($0.role)
        }
        let radios = window.nodes.filter { $0.enabled && $0.role == "AXRadioButton" }
        let labeled = try radios.compactMap { node -> (ZoomSlidesAXNode, Tab)? in
            let tabs = Set(node.text.compactMap(Tab.init(label:)))
            guard tabs.count <= 1 else { throw unsupported() }
            return tabs.first.map { (node, $0) }
        }
        if !legacy.isEmpty {
            guard legacy.count == 1, labeled.isEmpty else { throw unsupported() }
            let tab = legacy[0]
            switch ZoomSlidesDriver.normalized(tab.value) {
            case "files, 2 of 3": return nil
            case "screens, 1 of 3": return .key(tab.id, 124)
            case "more, 3 of 3": return .key(tab.id, 123)
            default: throw unsupported()
            }
        }

        func ancestors(of node: ZoomSlidesAXNode) throws -> [ZoomSlidesAXNode] {
            var result: [ZoomSlidesAXNode] = [], parent = node.parentID, seen: Set<String> = [node.id]
            while let id = parent {
                guard seen.insert(id).inserted else { throw unsupported() }
                guard let ancestor = byID[id] else { break }
                result.append(ancestor); parent = ancestor.parentID
            }
            return result
        }
        func group(of node: ZoomSlidesAXNode) throws -> String? {
            try ancestors(of: node).first { $0.role == "AXTabGroup" }?.id
        }
        let groups = try Set(labeled.map { item -> String in
            guard let id = try group(of: item.0) else { throw unsupported() }
            return id
        })
        guard groups.count == 1, let groupID = groups.first else { throw unsupported() }
        // An extra or renamed radio in this same group is not assumed to be a
        // harmless tab: it can change both selection and positional meaning.
        for node in radios where try group(of: node) == groupID {
            guard labeled.contains(where: { $0.0.id == node.id }) else { throw unsupported() }
        }
        var tabs: [Tab: [ZoomSlidesAXNode]] = [:]
        for (node, tab) in labeled { tabs[tab, default: []].append(node) }
        guard tabs.count == Tab.allCases.count else { throw unsupported() }
        var outer: [Tab: ZoomSlidesAXNode] = [:], selected = Set<Tab>()
        for tab in Tab.allCases {
            guard let nodes = tabs[tab], !nodes.isEmpty else { throw unsupported() }
            // Zoom 7.2 exposes an outer radio and a nested duplicate. Collapse
            // only an ancestor chain; two separate Files buttons stay ambiguous.
            let paths = try Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, Set(try ancestors(of: $0).map(\.id))) })
            for a in nodes {
                for b in nodes where a.id != b.id {
                    guard paths[a.id]!.contains(b.id) || paths[b.id]!.contains(a.id) else { throw unsupported() }
                }
            }
            let roots = nodes.filter { node in !nodes.contains { $0.id != node.id && paths[node.id]!.contains($0.id) } }
            guard roots.count == 1, let root = roots.first else { throw unsupported() }
            outer[tab] = root
            if try nodes.contains(where: isSelected) { selected.insert(tab) }
        }
        guard selected.count == 1 else { throw unsupported() }
        guard selected.first != .files else { return nil }
        guard let files = outer[.files] else { throw unsupported() }
        return .press(files.id)
    }

    private enum Tab: String, CaseIterable {
        case screens, windows, files, other
        init?(label: String) {
            switch ZoomSlidesDriver.normalized(label) {
            case "screens tab, 1 of 4": self = .screens
            case "windows tab, 2 of 4": self = .windows
            case "files tab, 3 of 4": self = .files
            case "other tab, 4 of 4": self = .other
            default: return nil
            }
        }
    }
    private static func isSelected(_ node: ZoomSlidesAXNode) throws -> Bool {
        if node.selected { return true }
        switch ZoomSlidesDriver.normalized(node.value) {
        case "on", "1", "true": return true
        case "", "off", "0", "false": return false
        default: throw unsupported()
        }
    }
    private static func unsupported() -> ZoomSlidesDriver.Failure {
        .unavailable("无法唯一确认共享选择器的 Files 标签或当前选择状态，未切换标签。")
    }
}
