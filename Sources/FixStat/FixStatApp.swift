import SwiftUI

@main
struct FixStatApp: App {
    @State private var monitor: Monitor

    init() {
        let monitor = Monitor()
        _monitor = State(initialValue: monitor)
        DispatchQueue.main.async { Snapshot.runIfRequested(monitor: monitor) }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(monitor)
        } label: {
            MenuBarLabel()
                .environment(monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Battery history", id: HistoryView.windowID) {
            HistoryView()
                .environment(monitor)
        }
        .defaultSize(width: 680, height: 640)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}
