import AppKit
import MacSensors

/// AppKit interface for macOS 10.13 – 13 (and `--legacy-ui`). Everything here must stay
/// available on macOS 10.13: no SwiftUI, no Combine, no FormatStyle, and no Swift
/// concurrency runtime (no Task / async / MainActor.assumeIsolated before macOS 10.15) —
/// use target/selector timers and main-thread callbacks instead.
@MainActor
final class LegacyApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var timer: Timer?

    static func run() {
        let app = NSApplication.shared
        let delegate = LegacyApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
