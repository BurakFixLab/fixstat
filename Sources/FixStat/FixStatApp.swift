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

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}
