import AppKit
import MacSensors
import FixStatCore

/// AppKit interface for macOS 10.13 – 13 (and `--legacy-ui`). Everything in this module
/// must work on macOS 10.13 – 11: no SwiftUI, no Combine, no FormatStyle, and nothing that
/// calls into the Swift concurrency runtime (missing before macOS 12, back-deployable only
/// to 10.15). The module is compiled in Swift 5 mode without actor annotations, because
/// Swift 6 inserts main-actor checks into @MainActor code called from AppKit, and those
/// crash on Big Sur. Use target/selector timers; AppKit calls everything on the main thread.
/// `scripts/simulate-old-macos.sh` runs the app with those libraries missing.
public final class LegacyApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    public static func run() {
        let app = NSApplication.shared
        let delegate = LegacyApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        refresh()
        let timer = Timer(timeInterval: 5, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func refresh() {
        let battery = BatteryReader.read()
        let percent = battery?.stateOfCharge.map { NumberFormatter.localizedString(from: NSNumber(value: $0 / 100), number: .percent) }
        statusItem?.button?.title = percent ?? "FixStat"

        let menu = NSMenu()
        if let b = battery {
            if let p = percent { menu.addItem(info(NSLocalizedString("Battery", comment: ""), p)) }
            if let h = b.healthPercent {
                menu.addItem(info(NSLocalizedString("Health", comment: ""),
                                  NumberFormatter.localizedString(from: NSNumber(value: h / 100), number: .percent)))
            }
            if let c = b.cycleCount { menu.addItem(info(NSLocalizedString("Cycles", comment: ""), String(c))) }
            menu.addItem(.separator())
        }
        let quit = NSMenuItem(title: NSLocalizedString("Quit", comment: ""), action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        statusItem?.menu = menu
    }

    private func info(_ title: String, _ value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(title): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
