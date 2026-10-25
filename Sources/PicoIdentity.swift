import Foundation
import AppKit

/// The product name may change without breaking existing users' data and grants.
/// The legacy bundle ID, preferences and directory are compatibility identifiers.
enum PicoIdentity {
    static let name = "Pico"
    static let bundleIdentifier = "com.telos.mac"

    @MainActor static func configureApplicationIcon(_ application: NSApplication, bundle: Bundle = .main) {
        // Load our own resource directly. Resolving the application through
        // NSWorkspace can reuse an older Dock/app-switcher icon after an update.
        guard let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              let resource = bundle.resourceURL?.appendingPathComponent(name),
              let image = NSImage(contentsOf: resource) else { return }
        image.isTemplate = false
        application.applicationIconImage = image
    }

    static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment,
                              home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let value = environment["TELOS_DATA_DIR"], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return home.appendingPathComponent("Library/Application Support/Telos", isDirectory: true)
    }
}

enum PicoStatusMark {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.scale(by: size / 35); transform.concat()
            let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 35, height: 35), xRadius: 12, yRadius: 12)
            path.append(NSBezierPath(roundedRect: NSRect(x: 8.71094, y: 12.25, width: 6.12496, height: 10.5), xRadius: 2.5, yRadius: 2.5))
            path.append(NSBezierPath(roundedRect: NSRect(x: 20.96, y: 12.25, width: 6.125, height: 10.5), xRadius: 2.5, yRadius: 2.5))
            path.windingRule = .evenOdd; NSColor.black.setFill(); path.fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
