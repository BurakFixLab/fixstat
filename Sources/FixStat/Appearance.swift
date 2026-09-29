import AppKit

/// Light / dark mode preference for all FixStat windows (panel, settings, history).
/// The status item itself always follows the menu bar.
@available(macOS 14.0, *)
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static var current: AppearancePreference {
        UserDefaults.standard.string(forKey: Pref.appearance).flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }

    /// Applies the saved preference, unless `--light` / `--dark` was passed on the
    /// command line (snapshots).
    @MainActor
    static func apply() {
        // UserDefaults notifications can arrive before NSApplication exists;
        // the launch-time call applies the preference once it does.
        guard let app = NSApp else { return }
        let arguments = CommandLine.arguments
        guard !arguments.contains("--light"), !arguments.contains("--dark") else { return }
        let target = current.appearance
        if app.appearance?.name != target?.name {
            app.appearance = target
        }
    }
}
