import AppKit
import SwiftUI

/// The window shown from the menu bar item.
struct PanelView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.technicianMode) private var technicianMode = false

    var body: some View {
        Group {
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

/// Settings / History / Quit buttons shared by both panels.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            present(windowIdentifier: "Settings") { openSettings() }
        }
        .keyboardShortcut(",")
    }
}

/// History, battery details and the post-repair test.
struct ToolsMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button("Battery history") { open(HistoryView.windowID) }
            Button("Battery details") { open(BatteryDetailsView.windowID) }
            Button("SSD health and test") { open(SSDView.windowID) }
            Button("Memory test") { open(MemoryView.windowID) }
            Button("Panic and shutdown history") { open(CrashHistoryView.windowID) }
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
@MainActor
private func closePanel() {
    for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
        if let button = window.contentView.flatMap(findStatusButton) {
            button.performClick(nil)
            return
        }
    }
}

@MainActor
private func findStatusButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    for subview in view.subviews {
        if let button = findStatusButton(in: subview) { return button }
    }
    return nil
}

struct QuitButton: View {
    var body: some View {
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
