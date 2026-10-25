import AppKit
import SwiftUI

/// A missing preference keeps Pico's existing dark appearance. "System" is an
/// explicit choice, so it must remove the native override rather than save dark.
enum PicoAppearance: String, CaseIterable, Identifiable {
    case light, dark, system
    static let preference = "PicoAppearance"
    var id: String { rawValue }
    var label: String {
        switch self { case .light: return "Light"; case .dark: return "Dark"; case .system: return "System" }
    }
    init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .dark }
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(savedValue: defaults.string(forKey: preference))
    }
    func save(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preference) }
    var colorScheme: ColorScheme? {
        switch self { case .light: return .light; case .dark: return .dark; case .system: return nil }
    }
    var nativeAppearance: NSAppearance? {
        switch self {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .system: return nil
        }
    }
    static func resolved(_ savedValue: String?, environment: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        if environment["TELOS_PREVIEW"] != nil,
           let preview = environment["TELOS_PREVIEW_APPEARANCE"], let mode = Self(rawValue: preview) {
            return mode
        }
        return Self(savedValue: savedValue)
    }
}

struct PicoAppearanceSettings: View {
    @AppStorage(PicoAppearance.preference) private var selection = PicoAppearance.dark.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Appearance").font(.system(size: 14, weight: .medium))
                Spacer(minLength: 8)
                Picker("Appearance", selection: $selection) {
                    ForEach(PicoAppearance.allCases) { mode in Text(mode.label).tag(mode.rawValue) }
                }.labelsHidden().pickerStyle(.menu).fixedSize()
                    .accessibilityLabel("Appearance").accessibilityIdentifier("picoAppearance")
            }
            Text(selection == PicoAppearance.system.rawValue
                 ? "Follows your Mac's light or dark appearance."
                 : "Applies immediately and stays saved on this Mac.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
