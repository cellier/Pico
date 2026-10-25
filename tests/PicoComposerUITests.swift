import AppKit
import SwiftUI

/// Exercise the actual shared native composer without an agent or user data.
/// Native editor/capsule frames and physical glyph positions guard against
/// first-character layout shifts and vertical recentering of the plus button.
@main struct PicoComposerUITests {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") } ?? "/tmp/pico-composer-ui-tests")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let model = ComposerFixtureState()
        let host = FirstMouseHostingView(rootView: ComposerGeometryFixture(model: model))
        host.sizingOptions = []; host.safeAreaRegions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 374, height: 528), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.contentView = host; window.isOpaque = false; window.backgroundColor = .clear
        window.level = .floating; window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        func settle(_ seconds: Double = 0.25) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func topRect(_ view: NSView) -> CGRect {
            let frame = view.convert(view.bounds, to: host)
            return host.isFlipped ? frame : CGRect(x: frame.minX, y: host.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        }
        func editor() -> AttachmentTextView { model.draft.editor! }
        func field() -> CGRect { topRect(model.draft.hitSurface!) }
        func textViewport() -> CGRect { topRect(editor().enclosingScrollView!) }
        func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.6) -> Bool { abs(a-b) <= tolerance }
        func whiteCaret() {
            let color = editor().insertionPointColor.usingColorSpace(.deviceRGB)!
            precondition(min(color.redComponent, color.greenComponent, color.blueComponent) > 0.98 && color.alphaComponent > 0.98,
                         "Native insertion caret must stay white after editor updates")
        }
        func setText(_ text: String) {
            model.draft.setText(text); settle()
            window.makeFirstResponder(editor()); whiteCaret()
        }
        func elements(_ root: Any, depth: Int = 0) -> [NSObject] {
            guard depth < 16, let value = root as? NSObject else { return [] }
            let children = (value as? any NSAccessibilityProtocol)?.accessibilityChildren()
                ?? (value.accessibilityAttributeValue(.children) as? [Any]) ?? []
            return [value] + children.flatMap { elements($0, depth: depth + 1) }
        }
        func attribute(_ element: NSObject, _ name: String, _ legacy: NSAccessibility.Attribute) -> String {
            let selector = NSSelectorFromString(name)
            if element.responds(to: selector), let value = element.perform(selector)?.takeUnretainedValue() as? String { return value }
            return element.accessibilityAttributeValue(legacy) as? String ?? ""
        }
        func control(_ label: String, enabled: Bool = true) -> NSObject {
            guard let value = elements(host).first(where: {
                attribute($0, "accessibilityIdentifier", .identifier) == "composerGeometryField-send"
            }) else { fatalError("Missing composer action") }
            precondition(attribute(value, "accessibilityLabel", .description) == label,
                         "Composer must present \(label) for the current draft and running state")
            precondition((value.accessibilityAttributeValue(.enabled) as? Bool) == enabled,
                         "\(label) enablement must respect send availability and IME composition")
            return value
        }
        func press(_ label: String) {
            let value = control(label), selector = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            precondition(value.responds(to: selector))
            precondition(unsafeBitCast(value.method(for: selector), to: Press.self)(value, selector))
            settle()
        }
        func enter(_ modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
            editor().keyDown(with: event); settle()
        }
        model.running = true; setText("继续补充这条消息")
        press("Send")
        precondition(model.submits == 1 && model.stops == 0, "A running Chat must send the new draft without stopping the reply")
        enter()
        precondition(model.submits == 2 && model.stops == 0, "Return must send while Chat is replying")
        enter(.shift)
        precondition(model.submits == 2 && model.draft.text.contains("\n"), "Shift-Return must insert a line break without sending")
        setText("")
        editor().setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        settle()
        precondition(model.draft.isComposing && editor().hasMarkedText())
        _ = control("Send", enabled: false)
        enter()
        precondition(model.submits == 2 && model.stops == 0, "Confirming an IME candidate must never send or stop the active reply")
        editor().unmarkText(); setText("")
        press("Stop")
        precondition(model.stops == 1 && model.submits == 2, "An empty running composer must retain Stop")
        model.canSend = false; setText("Task follow-up waits for the current task")
        press("Stop"); enter()
        precondition(model.stops == 2 && model.submits == 2, "A task that cannot accept another message must retain its previous Stop behavior")
        model.running = false; model.canSend = true; setText("Next message")
        _ = control("Send")
        model.submits = 0; model.stops = 0; setText("")
        print("PASS actual shared Composer: send while replying, Return, IME confirmation, Shift-Return, empty-draft Stop and task restrictions")
        if CommandLine.arguments.contains("--behavior-only") { return }
        func capture(_ name: String) throws -> URL {
            window.contentView?.needsDisplay = true; window.displayIfNeeded(); settle(0.1)
            let url = output.appendingPathComponent(name + ".png")
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
            try process.run(); process.waitUntilExit()
            precondition(process.terminationStatus == 0, "Actual WindowServer capture is required for glyph geometry")
            return url
        }
        func glyph(_ url: URL, xRange: ClosedRange<CGFloat>) throws -> (center: CGPoint, count: Int)? {
            let image = NSBitmapImageRep(data: try Data(contentsOf: url))!
            let scale = CGFloat(image.pixelsWide) / host.bounds.width
            var minX = image.pixelsWide, minY = image.pixelsHigh, maxX = -1, maxY = -1, count = 0
            let lowerY = Int(max(0, (host.bounds.height - 190) * scale))
            let upperY = min(image.pixelsHigh - 1, Int((host.bounds.height - 16) * scale))
            for y in lowerY...upperY {
                for x in Int(xRange.lowerBound * scale)...Int(xRange.upperBound * scale) {
                    let c = image.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    // Composer action uses an88% foreground; glass and rims stay
                    // below this threshold, including the reserved empty slot.
                    if min(c.redComponent, c.greenComponent, c.blueComponent) > 0.80 {
                        minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y); count += 1
                    }
                }
            }
            guard count > 8 else { return nil }
            return (CGPoint(x: (CGFloat(minX + maxX) + 1) / (2 * scale), y: (CGFloat(minY + maxY) + 1) / (2 * scale)), count)
        }
        func plus(_ url: URL) throws -> CGPoint {
            guard let result = try glyph(url, xRange: 24...48) else { fatalError("Leading plus must remain visibly rendered") }
            return result.center
        }
        func action(_ url: URL) throws -> CGPoint? {
            try glyph(url, xRange: (field().maxX - 33)...(field().maxX - 7))?.center
        }
        func stable(_ baselineField: CGRect, _ baselineEditor: CGRect, _ context: String) {
            let currentField = field(), currentEditor = textViewport()
            precondition(close(currentField.minX, baselineField.minX) && close(currentField.width, baselineField.width)
                         && close(currentField.height, baselineField.height) && close(currentField.maxY, baselineField.maxY),
                         "First character/action visibility changed capsule geometry: \(context), \(baselineField)→\(currentField)")
            precondition(close(currentEditor.width, baselineEditor.width) && close(currentEditor.height, baselineEditor.height),
                         "Editor width/height changed when Send appeared: \(context)")
        }
        let sizes = [CGSize(width: 340, height: 420), CGSize(width: 374, height: 528), CGSize(width: 560, height: 720)]
        for size in sizes {
            model.running = false; setText(""); window.setContentSize(size); window.center(); settle(0.5)
            let stem = "\(Int(size.width))x\(Int(size.height))"
            let emptyField = field(), emptyEditor = textViewport()
            precondition(close(emptyField.height,40) && close(emptyEditor.height,20), "Single-line composer must remain40pt with20pt editor")
            precondition(close(emptyField.maxY,size.height-16), "Composer must be anchored16pt above the window bottom")
            let empty = try capture(stem + "-empty")
            let plusEmpty = try plus(empty)
            precondition(close(plusEmpty.y,emptyField.maxY-20,1.5), "Leading40pt plus must be bottom aligned")
            let emptyAction = try action(empty)
            precondition(emptyAction == nil, "Empty input must hide Send without removing its reserved slot")

            editor().insertText("中", replacementRange: NSRange(location: 0, length: 0)); settle()
            whiteCaret(); stable(emptyField,emptyEditor,"native first Chinese character")
            let one = try capture(stem + "-one-character")
            let plusOne = try plus(one)
            precondition(close(plusOne.x,plusEmpty.x) && close(plusOne.y,plusEmpty.y), "Plus shifted on first character")
            guard let sendOne = try action(one) else { fatalError("Send must appear after first character") }
            for index in 0..<6 {
                setText(index.isMultiple(of:2) ? "" : "A")
                stable(emptyField,emptyEditor,"repeated clear/type \(index)")
            }
            setText("第一行 mixed text.\n第二行 English 和中文。\n第三行 continues here.")
            let expanded = field()
            precondition(expanded.height > emptyField.height && expanded.minY < emptyField.minY && close(expanded.maxY,emptyField.maxY),
                         "Multiline must expand upward with a fixed bottom")
            precondition(close(expanded.width,emptyField.width), "Multiline cannot resize input width")
            let multiline = try capture(stem + "-multiline")
            let plusExpanded = try plus(multiline)
            precondition(close(plusExpanded.x,plusEmpty.x) && close(plusExpanded.y,plusEmpty.y), "Plus moved upward with multiline input")
            guard let sendExpanded = try action(multiline) else { fatalError("Expanded input must retain Send") }
            precondition(close(sendExpanded.x,sendOne.x,1) && close(sendExpanded.y,sendOne.y,1), "Send must remain at bottom-right")

            setText(String(repeating: "更多中文 and English for native editor scrolling.\n", count: 60))
            precondition(close(model.draft.editorHeight,144) && close(textViewport().height,144) && close(field().maxY,emptyField.maxY),
                         "Long input must cap native editor at144pt while bottom stays fixed")
            editor().layoutManager?.ensureLayout(for: editor().textContainer!)
            editor().scrollRangeToVisible(NSRange(location: editor().string.utf16.count, length: 0)); settle()
            precondition(editor().enclosingScrollView!.contentView.bounds.origin.y > 1,
                         "Capped multiline editor must actually scroll to its last line")
            let capped = try capture(stem + "-capped-scrolled")
            let plusCapped = try plus(capped)
            precondition(close(plusCapped.x,plusEmpty.x) && close(plusCapped.y,plusEmpty.y), "Plus moved when editor hit its cap")
            setText(""); stable(emptyField,emptyEditor,"clear after capped input")
            model.running = true; settle()
            stable(emptyField,emptyEditor,"Stop visible with empty input")
            let running = try capture(stem + "-running-stop")
            guard let stop = try action(running) else { fatalError("Running state must show Stop") }
            precondition(close(stop.x,sendOne.x,1) && close(stop.y,sendOne.y,1), "Stop cannot change action slot position")
            model.running = false; settle(); stable(emptyField,emptyEditor,"idle after Stop")
            print("PASS \(stem): empty/first-char/repeated toggles stable; multiline grows upward; plus fixed; Send/Stop fixed;144pt native scroll; white caret")
        }
        precondition(model.submits == 0 && model.stops == 0, "Geometry QA must not submit work")
        print("PASS shared Composer native geometry; physical screenshots: \(output.path)")
    }
}

@MainActor private final class ComposerFixtureState: ObservableObject {
    let draft = ComposerDraft()
    @Published var running = false
    @Published var canSend = true
    var submits = 0
    var stops = 0
}
private struct ComposerGeometryFixture: View {
    @ObservedObject var model: ComposerFixtureState
    private let shape = RoundedRectangle(cornerRadius: 38, style: .continuous)
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            Composer(draft: model.draft, placeholder: "Message", canSend: model.canSend, identifier: "composerGeometryField", isRunning: model.running,
                     stopAction: { model.stops += 1 }, action: { model.submits += 1 })
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LinearGradient(stops: [.init(color: .black.opacity(0.99), location: 0), .init(color: .black.opacity(0.97), location: 0.8), .init(color: .black.opacity(0.4), location: 1)], startPoint: .top, endPoint: .bottom), in: shape)
            .modifier(PanelGlass(shape: shape)).clipShape(shape)
            .environment(\.colorScheme, .dark).foregroundStyle(.white)
    }
}
