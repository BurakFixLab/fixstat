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
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
    }
}

struct QuitButton: View {
    var body: some View {
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
