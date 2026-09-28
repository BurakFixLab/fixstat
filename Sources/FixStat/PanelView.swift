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
        .onAppear { monitor.panelVisible = true }
        .onDisappear { monitor.panelVisible = false }
    }
}

/// Settings / Quit buttons shared by both panels.
struct SettingsButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings…") {
            closePanel()
            NSApp.activate()
            openSettings()
            // A menu bar (LSUIElement) app does not bring the newly created
            // Settings window to the front by itself.
            DispatchQueue.main.async {
                NSApp.activate()
                NSApp.windows
                    .first { $0.identifier?.rawValue.contains("Settings") == true }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        .keyboardShortcut(",")
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
