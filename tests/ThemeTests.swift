import AppKit
import SwiftUI
@main struct ThemeTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: TelosTheme.surface.frame(width: 100, height: 100))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        precondition(window.appearance == nil, "Default follows system/application appearance")
        func brightness(_ appearance: NSAppearance.Name) -> CGFloat {
            app.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        let light = brightness(.aqua), dark = brightness(.darkAqua), restored = brightness(.aqua)
        precondition(light > 0.9 && dark < 0.25 && restored > 0.9, "Live light/dark/light switching")
        window.orderOut(nil); app.appearance = nil
        print("PASS: inherited appearance, live light → dark → light rendering")
    }
}
