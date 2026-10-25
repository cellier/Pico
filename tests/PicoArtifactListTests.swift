import AppKit
import SwiftUI

/// The regression was thousands of media-file buttons inside a single row,
/// rather than a long message. Exercise the actual SwiftUI accessibility tree.
@main struct PicoArtifactListTests {
    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let files = (0..<3763).map { Artifact(path: "/private/pico-fixture/frame-\($0).png", name: "frame-\($0).png") }
        var visited: [String] = []
        for page in 0...((files.count - 1) / PicoFileListPage.size) {
            let range = PicoFileListPage.range(count: files.count, page: page)
            precondition(range.count <= 24)
            visited += files[range].map(\.path)
        }
        precondition(visited == files.map(\.path), "Replacement pages must keep every file reachable exactly once")
        precondition(PicoFileListPage.range(count: 0, page: 9).isEmpty)
        precondition(PicoFileListPage.range(count: 3, page: 9) == 0..<3)
        precondition(PicoFileListPage.range(count: files.count, page: Int.max) == 3744..<3763)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: PicoArtifactList(artifacts: files,
            folderURL: URL(fileURLWithPath: "/private/pico-fixture"), openArtifact: { _ in fatalError("No external file should open") }))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 550, height: 1000),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        }
        // SwiftUI's virtual AccessibilityNode uses the informal NSObject API;
        // it deliberately does not conform to NSAccessibilityProtocol.
        func elements(_ root: Any) -> [NSObject] {
            guard let element = root as? NSObject else { return [] }
            let children = (element as? any NSAccessibilityProtocol)?.accessibilityChildren()
                ?? (element.accessibilityAttributeValue(.children) as? [Any]) ?? []
            return [element] + children.flatMap(elements)
        }
        func identifier(_ element: NSObject) -> String {
            let selector = NSSelectorFromString("accessibilityIdentifier")
            if element.responds(to: selector), let value = element.perform(selector)?.takeUnretainedValue() as? String { return value }
            return element.accessibilityAttributeValue(.identifier) as? String ?? ""
        }
        func fileButtons() -> [NSObject] {
            elements(host).filter { identifier($0).hasPrefix("chatArtifact-") }
        }
        settle()
        print("AX objects", elements(host).count, "files", fileButtons().count)
        precondition(fileButtons().count == 24, "Only24 file buttons may exist in the real accessibility tree")
        let next = elements(host).first { identifier($0) == "artifactNextPage" }!
        let press = NSSelectorFromString("accessibilityPerformPress")
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        precondition(next.responds(to: press))
        precondition(unsafeBitCast(next.method(for: press), to: Press.self)(next, press))
        settle()
        precondition(fileButtons().count == 24)
        let names = Set(fileButtons().map(identifier))
        precondition(names == Set(files[24..<48].map { "chatArtifact-" + $0.path }),
                     "Next must replace the first page, never append more buttons")
        precondition(elements(host).contains { identifier($0) == "artifactFolder" })
        print("PASS3763 synthetic media artifacts:24 actual file buttons before/after Next;157 replacement pages preserve all3763 paths; Finder entry exists; no external actions")
    }
}
