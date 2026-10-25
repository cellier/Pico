import Foundation

enum ZoomSharePickerTabsTests {
    static func run() throws {
        for (value, expected) in [
            ("Screens, 1 of 3", ZoomSlidesAXAction.key("legacy", 124)),
            ("More, 3 of 3", ZoomSlidesAXAction.key("legacy", 123))
        ] {
            try check(legacy(value), expected)
        }
        try check(legacy("Files, 2 of 3"), nil)
        try rejected(legacy("Files, 3 of 4"))
        var duplicateLegacy = legacy("Screens, 1 of 3")
        duplicateLegacy.nodes.append(.init(id: "second-switch", role: "AXTabGroup", description: "Switch", value: "Files, 2 of 3"))
        try rejected(duplicateLegacy)

        for selected in 0..<4 {
            for nested in [false, true] {
                let picker = modern(selected: selected, nested: nested)
                let expected: ZoomSlidesAXAction? = selected == 2 ? nil : .press("files-outer")
                try check(picker, expected, "Files must resolve from every current tab, collapsing only its nested duplicate")
            }
        }
        for value in ["on", "1", "true"] {
            var picker = modern(selected: nil)
            picker.nodes[1].value = value
            try check(picker, .press("files-outer"))
        }
        var selectedFlag = modern(selected: nil)
        selectedFlag.nodes[1].selected = true
        try check(selectedFlag, .press("files-outer"))
        var nestedSelection = modern(selected: nil, nested: true)
        nestedSelection.nodes.firstIndex(where: { $0.id == "files-inner" }).map { nestedSelection.nodes[$0].value = "on" }
        try check(nestedSelection, nil, "the nested radio may expose the selected value")

        try rejected(modern(selected: nil))
        var multiple = modern(selected: 0)
        multiple.nodes.firstIndex(where: { $0.id == "files-outer" }).map { multiple.nodes[$0].value = "on" }
        try rejected(multiple)
        var duplicate = modern(selected: 0, nested: true)
        duplicate.nodes.append(.init(id: "other-files", role: "AXRadioButton", description: "Files Tab, 3 of 4", value: "off", parentID: "tabs"))
        try rejected(duplicate)
        var unknown = modern(selected: 0)
        unknown.nodes[3].description = "Files Tab, 3 of 5"
        try rejected(unknown)
        var extra = modern(selected: 0)
        extra.nodes.append(.init(id: "unknown-tab", role: "AXRadioButton", description: "Audio Tab, 5 of 5", value: "off", parentID: "tabs"))
        try rejected(extra)
        var unknownSelection = modern(selected: nil)
        unknownSelection.nodes[1].value = "maybe"
        try rejected(unknownSelection)
        var noGroup = modern(selected: 0)
        noGroup.nodes.removeFirst()
        try rejected(noGroup)
        var separateGroups = modern(selected: 0)
        separateGroups.nodes += modern(selected: 2).nodes.map { original in
            var node = original; node.id += "-second"; node.parentID = node.parentID.map { $0 + "-second" }; return node
        }
        try rejected(separateGroups)
        var mixed = modern(selected: 0)
        mixed.nodes += legacy("Files, 2 of 3").nodes
        try rejected(mixed)
        print("PASS: Zoom sharing Files tab supports legacy Switch and four radio tabs; nested duplicates, selection and ambiguity remain bounded")
    }

    private static func action(_ picker: ZoomSlidesAXWindow) throws -> ZoomSlidesAXAction? {
        try ZoomSharePickerTabs.filesAction(in: picker)
    }
    private static func check(_ picker: ZoomSlidesAXWindow, _ expected: ZoomSlidesAXAction?, _ message: String = "the Files action must match the verified tab layout") throws {
        let actual = try action(picker)
        precondition(actual == expected, message)
    }
    private static func rejected(_ picker: ZoomSlidesAXWindow) throws {
        do { _ = try action(picker); preconditionFailure("an ambiguous or unsupported picker must not dispatch a tab action") }
        catch let failure as ZoomSlidesDriver.Failure {
            guard case .unavailable = failure else { throw failure }
        }
    }
    private static func legacy(_ value: String) -> ZoomSlidesAXWindow {
        .init(id: "picker", title: "Share screen window", nodes: [
            .init(id: "legacy", role: "AXTabGroup", description: "Switch", value: value)
        ])
    }
    private static func modern(selected: Int?, nested: Bool = false) -> ZoomSlidesAXWindow {
        var nodes = [ZoomSlidesAXNode(id: "tabs", role: "AXTabGroup")]
        for (index, name) in ["Screens", "Windows", "Files", "Other"].enumerated() {
            let prefix = name.lowercased(), label = "\(name) Tab, \(index + 1) of 4"
            nodes.append(.init(id: prefix + "-outer", role: "AXRadioButton", description: label,
                               value: selected == index ? "on" : "off", parentID: "tabs"))
            if nested {
                nodes.append(.init(id: prefix + "-inner", role: "AXRadioButton", description: label,
                                   value: selected == index ? "on" : "off", parentID: prefix + "-outer"))
            }
        }
        return .init(id: "picker", title: "Share screen window", nodes: nodes)
    }
}
