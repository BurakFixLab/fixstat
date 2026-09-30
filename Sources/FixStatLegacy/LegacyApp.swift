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
public final class LegacyApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var core: MonitorCore!
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var panel: LegacyPanelController!
    private var settings: LegacySettingsController?
    private var tools: LegacyTools!
    private var defaultsObserver: NSObjectProtocol?
    private var popoverMonitor: Any?

    public static func run() {
        let app = NSApplication.shared
        let delegate = LegacyApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        core = MonitorCore()
        panel = LegacyPanelController(core: core) { [unowned self] in showSettings() }
        panel.onResize = { [unowned self] size in popover.contentSize = size }
        tools = LegacyTools(core: core)
        panel.tools = tools
        panel.closePanel = { [unowned self] in popover.performClose(nil) }
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        LegacyAppearance.apply()
        if LegacySnapshot.runIfRequested(core: core, panel: panel, tools: tools, settings: { [unowned self] in makeSettings() }) {
            return
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover(_:))
        item.button?.imagePosition = .imageLeft
        statusItem = item

        core.onUpdate = { [unowned self] in
            updateStatusItem()
            if popover.isShown { panel.update() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [unowned self] _ in
            LegacyAppearance.apply()
            updateStatusItem()
            if popover.isShown { panel.update() }
        }
        updateStatusItem()
    }

    // MARK: Status item

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let defaults = UserDefaults.standard
        let showIcon = defaults.bool(forKey: Pref.menuBarBatteryIcon)
        var parts: [String] = []
        if defaults.bool(forKey: Pref.menuBarBatteryPercent), let soc = core.battery?.stateOfCharge {
            parts.append(Format.percent(soc))
        }
        if defaults.bool(forKey: Pref.menuBarCPUTemperature), let cpu = core.cpuTemperature {
            parts.append(Format.degrees(cpu))
        }
        let title = parts.joined(separator: " · ")
        if showIcon, core.battery != nil {
            button.image = BatteryIcon.image(for: core.battery)
        } else if parts.isEmpty {
            button.image = Self.thermometer
        } else {
            button.image = nil
        }
        let text = title.isEmpty ? "" : (button.image == nil ? title : " " + title)
        if button.title != text {
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            ])
        }
        button.setAccessibilityLabel("FixStat")
    }

    private static var thermometer: NSImage? {
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: "thermometer", accessibilityDescription: "FixStat")
        }
        return nil
    }

    // MARK: Popover

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem?.button {
            if let screen = button.window?.screen ?? NSScreen.main {
                // Room below the menu bar, minus the popover's arrow and a small gap.
                panel.maxHeight = screen.visibleFrame.height - 24
            }
            panel.update()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func popoverDidShow(_ notification: Notification) {
        core.panelVisible = true
        // A transient popover only closes on outside clicks while FixStat is active.
        popoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        core.panelVisible = false
        if let popoverMonitor { NSEvent.removeMonitor(popoverMonitor) }
        popoverMonitor = nil
    }

    // MARK: Settings

    private func makeSettings() -> LegacySettingsController {
        if let settings { return settings }
        let controller = LegacySettingsController(core: core)
        settings = controller
        return controller
    }

    private func showSettings() {
        popover.performClose(nil)
        let controller = makeSettings()
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}

/// System / Light / Dark setting (dark mode exists from macOS 10.14).
enum LegacyAppearance {
    static func apply() {
        guard let app = NSApp else { return }
        let arguments = CommandLine.arguments
        if #available(macOS 10.14, *) {
            let name: NSAppearance.Name?
            if arguments.contains("--dark") {
                name = .darkAqua
            } else if arguments.contains("--light") {
                name = .aqua
            } else {
                switch UserDefaults.standard.string(forKey: Pref.appearance) {
                case "light": name = .aqua
                case "dark": name = .darkAqua
                default: name = nil
                }
            }
            let target = name.flatMap(NSAppearance.init(named:))
            if app.appearance?.name != target?.name { app.appearance = target }
        }
    }
}

/// `--legacy-ui --snapshot out.png [--technician] [--settings 0|1|2] [--max-height N]
/// [--tool device|history|details|crash|sleep|stress|memory|ssd|capacity [--wait SECONDS] [--range 0…6] [--start-test SECONDS]]`: renders the AppKit
/// panel or a Settings tab to PNG and exits (UI checks without clicking).
enum LegacySnapshot {
    static func runIfRequested(core: MonitorCore, panel: LegacyPanelController, tools: LegacyTools,
                               settings: () -> LegacySettingsController) -> Bool {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return false }
        let url = URL(fileURLWithPath: arguments[index + 1])
        UserDefaults.standard.set(arguments.contains("--technician"), forKey: Pref.technicianMode)
        // `--max-height N`: as on a smaller screen (11" MacBook Air: 768 px).
        if let i = arguments.firstIndex(of: "--max-height"), i + 1 < arguments.count, let height = Double(arguments[i + 1]) {
            panel.maxHeight = CGFloat(height)
        }
        core.panelVisible = true

        // The captured view draws its own window background (light or dark).
        let capture: NSView
        let window: NSWindow
        var fitsContent = false
        let toolNames: [String: LegacyTools.Tool] = ["device": .deviceInfo, "details": .batteryDetails,
                                                     "crash": .crashHistory, "sleep": .sleep, "history": .history,
                                                     "stress": .stressTest, "memory": .memory, "ssd": .ssd, "capacity": .capacity]
        if let i = arguments.firstIndex(of: "--range"), i + 1 < arguments.count,
           let range = Int(arguments[i + 1]).flatMap(HistoryRange.init(rawValue:)) {
            LegacyTools.initialRange = range
        }
        var wait = 2.5
        if let i = arguments.firstIndex(of: "--wait"), i + 1 < arguments.count, let seconds = Double(arguments[i + 1]) {
            wait = seconds
        }
        if let i = arguments.firstIndex(of: "--tool"), i + 1 < arguments.count, let tool = toolNames[arguments[i + 1]] {
            let toolWindow = tools.window(tool)
            toolWindow.onOpen?()
            toolWindow.reload()
            if let i = arguments.firstIndex(of: "--start-test"), i + 1 < arguments.count,
               let seconds = Double(arguments[i + 1]), let test = tools.controller(tool) as? LegacySnapshotStartable {
                test.start(seconds: seconds)
            }
            guard let w = toolWindow.window, let frame = w.contentView?.superview else { exit(1) }
            window = w
            capture = frame
        } else if let i = arguments.firstIndex(of: "--settings"), i + 1 < arguments.count, let tab = Int(arguments[i + 1]) {
            let controller = settings()
            controller.select(tab: tab)
            guard let settingsWindow = controller.window, let frame = settingsWindow.contentView?.superview else { exit(1) }
            window = settingsWindow
            capture = frame
        } else {
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 0
            box.cornerRadius = 0
            box.fillColor = .windowBackgroundColor
            box.contentViewMargins = .zero
            box.contentView = panel.view
            window = NSWindow(contentRect: NSRect(origin: .zero, size: panel.view.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = box
            capture = box
            fitsContent = true
        }
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        // Wait for a second refresh (CPU usage needs a delta).
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            core.refresh()
            panel.update()
            if fitsContent { window.setContentSize(panel.view.fittingSize) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                capture.layoutSubtreeIfNeeded()
                guard let rep = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else { exit(1) }
                capture.cacheDisplay(in: capture.bounds, to: rep)
                do {
                    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
                    try png.write(to: url)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
        return true
    }
}
