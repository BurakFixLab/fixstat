import AppKit
import SwiftUI
import FixStatCore

/// The window shown from the menu bar item.
@available(macOS 14.0, *)
struct PanelView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.technicianMode) private var technicianMode = false

    var body: some View {
        VStack(spacing: Design.cardSpacing) {
            if case let .available(release) = monitor.update {
                UpdateBanner(release: release)
            }
            if technicianMode {
                TechnicianPanel()
            } else {
                DefaultPanel()
            }
        }
        .frame(width: 360)
        .padding(14)
        .background(PanelWindowObserver { visible in monitor.panelVisible = visible })
    }
}

/// "FixStat 1.3 is available" with a link to the release page.
@available(macOS 14.0, *)
struct UpdateBanner: View {
    let release: UpdateChecker.Release

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint)
            Text("FixStat \(release.version) is available")
            Spacer(minLength: 4)
            Link("Download", destination: release.url).fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.cardRadius))
    }
}

/// Settings / History / Quit buttons shared by both panels.
@available(macOS 14.0, *)
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            present(windowIdentifier: "Settings") { openSettings() }
        }
        .keyboardShortcut(",")
        .fixedSize()
    }
}

/// History, battery details and the post-repair test.
@available(macOS 14.0, *)
struct ToolsMenu: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Menu {
            Button("Device info") { open(DeviceInfoView.windowID) }
            Divider()
            // No battery tools on an iMac, a Mac mini or a notebook without its battery.
            if monitor.profile.hasBattery {
                Button("Battery history") { open(HistoryView.windowID) }
                Button("Battery details") { open(BatteryDetailsView.windowID) }
                Button("Battery capacity test") { open(CapacityTestView.windowID) }
            }
            Button("SSD health and test") { open(SSDView.windowID) }
            Button("Memory test") { open(MemoryView.windowID) }
            Button("Panic and shutdown history") { open(CrashHistoryView.windowID) }
            Button("Sleep and wake") { open(SleepView.windowID) }
            Button("Power analysis") { open(PowerView.windowID) }
            Button("Post-repair test") { open(TestView.windowID) }
            Button("Hardware check") { open(HardwareCheckView.windowID) }
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .fixedSize()
    }

    private func open(_ id: String) {
        present(windowIdentifier: id) { openWindow(id: id) }
    }
}

@available(macOS 14.0, *)
struct DetailsLink: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Details") {
            present(windowIdentifier: BatteryDetailsView.windowID) { openWindow(id: BatteryDetailsView.windowID) }
        }
        .buttonStyle(.link)
        .font(.caption)
    }
}

/// Opens a window from the menu bar panel: closes the panel, activates the app
/// and brings the window to the front (a menu bar / LSUIElement app does not do
/// that by itself for newly created windows).
@available(macOS 14.0, *)
@MainActor
private func present(windowIdentifier: String, open: () -> Void) {
    closePanel()
    NSApp.activate()
    open()
    DispatchQueue.main.async {
        NSApp.activate()
        NSApp.windows
            .first { $0.identifier?.rawValue.contains(windowIdentifier) == true }?
            .makeKeyAndOrderFront(nil)
    }
}

/// Closes the menu bar panel so it does not float above the Settings window.
///
/// Hiding the panel window directly leaves MenuBarExtra believing it is still
/// open (the next click on the status item then does nothing), so this toggles
/// it the same way a click on the status item does.
@available(macOS 14.0, *)
@MainActor
private func closePanel() {
    for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
        if let button = window.contentView.flatMap(findStatusButton) {
            button.performClick(nil)
            return
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private func findStatusButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    for subview in view.subviews {
        if let button = findStatusButton(in: subview) { return button }
    }
    return nil
}

@available(macOS 14.0, *)
struct QuitButton: View {
    var body: some View {
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
            .fixedSize()
    }
}
