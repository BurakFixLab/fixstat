import AppKit

/// FixStat is a menu bar app (LSUIElement), and macOS readily pushes the windows of such
/// apps behind others, with no Dock icon or ⌘-Tab entry to bring them back. While a
/// FixStat window is open (or when the user wants it always), the app becomes a regular
/// app with a Dock icon; with no window left it goes back to the menu bar only.
public enum DockIcon {
    private static var observers: [NSObjectProtocol] = []
    private static var pending = false

    /// Starts following the windows; call once at launch (NSApp must exist).
    public static func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                                          NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, UserDefaults.didChangeNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in scheduleUpdate() })
        }
        update()
    }

    /// After the current event: a closing window is still visible while it closes.
    private static func scheduleUpdate() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async {
            pending = false
            update()
        }
    }

    /// Titled windows the user works with: tool windows and Settings. Not the menu bar
    /// panel or popover, sheets, alerts and save panels (panels), or the full-screen
    /// display test (borderless).
    private static var hasOpenWindow: Bool {
        NSApp.windows.contains { window in
            window.styleMask.contains(.titled) && !(window is NSPanel) && window.sheetParent == nil
                && (window.isVisible || window.isMiniaturized)
                && window.frame.maxX > -5_000 // snapshots render off screen
        }
    }

    private static func update() {
        guard let app = NSApp else { return }
        let regular = UserDefaults.standard.bool(forKey: Pref.showInDock) || hasOpenWindow
        let policy: NSApplication.ActivationPolicy = regular ? .regular : .accessory
        guard app.activationPolicy() != policy else { return }
        app.setActivationPolicy(policy)
        if regular {
            // Becoming a regular app does not activate it by itself.
            app.activate(ignoringOtherApps: true)
        }
    }
}
