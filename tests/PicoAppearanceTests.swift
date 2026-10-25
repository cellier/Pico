import AppKit
import SwiftUI

@main struct PicoAppearanceTests {
    @MainActor static func main() {
        let domain = "pico-appearance-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        precondition(PicoAppearance.saved(in: defaults) == .dark, "Existing users retain dark when no preference exists")
        defaults.set("invalid-value", forKey: PicoAppearance.preference)
        precondition(PicoAppearance.saved(in: defaults) == .dark, "An invalid preference has a stable dark fallback")
        for mode in PicoAppearance.allCases {
            mode.save(in: defaults)
            precondition(PicoAppearance.saved(in: UserDefaults(suiteName: domain)!) == mode, "Each choice persists across settings instances")
        }
        precondition(PicoAppearance.system.colorScheme == nil && PicoAppearance.system.nativeAppearance == nil,
                     "System removes both SwiftUI and AppKit overrides")
        precondition(PicoAppearance.resolved("system", environment: [:]) == .system)
        precondition(PicoAppearance.resolved("dark", environment: ["TELOS_PREVIEW_APPEARANCE": "light"]) == .dark,
                     "Preview-only flags cannot alter normal application appearance")
        precondition(PicoAppearance.resolved("dark", environment: ["TELOS_PREVIEW": "settings", "TELOS_PREVIEW_APPEARANCE": "light"]) == .light)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let oldAppearance = app.appearance
        defer { app.appearance = oldAppearance }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TelosTheme.surface.frame(width: 100, height: 100))
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        func brightness() -> CGFloat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return bitmap.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!.redComponent
        }
        app.appearance = NSAppearance(named: .aqua)
        window.appearance = PicoAppearance.dark.nativeAppearance
        precondition(brightness() < 0.15, "Dark overrides a light system")
        window.appearance = PicoAppearance.light.nativeAppearance
        precondition(brightness() > 0.9, "Light updates the existing native host")
        app.appearance = NSAppearance(named: .darkAqua)
        precondition(brightness() > 0.9, "Light remains light when the system changes")
        window.appearance = PicoAppearance.system.nativeAppearance
        precondition(brightness() < 0.15, "System follows dark without recreating the window")
        app.appearance = NSAppearance(named: .aqua)
        precondition(brightness() > 0.9, "System follows a live return to light")
        print("PASS: dark default, all three choices persist, native host switches light/dark/system live")
    }
}
