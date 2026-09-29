import SwiftUI

@main
struct FixStatApp: App {
    @State private var monitor: Monitor
    @State private var testRunner: TestRunner
    @State private var ssdRunner: SSDTestRunner

    init() {
        let monitor = Monitor()
        _monitor = State(initialValue: monitor)
        _testRunner = State(initialValue: TestRunner(monitor: monitor))
        _ssdRunner = State(initialValue: SSDTestRunner(monitor: monitor))
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

        Window("Post-repair test", id: TestView.windowID) {
            TestView()
                .environment(monitor)
                .environment(testRunner)
        }
        .defaultSize(width: 640, height: 640)

        Window("Panic and shutdown history", id: CrashHistoryView.windowID) {
            CrashHistoryView()
                .environment(monitor)
        }
        .defaultSize(width: 680, height: 600)

        Window("SSD", id: SSDView.windowID) {
            SSDView()
                .environment(ssdRunner)
        }
        .defaultSize(width: 660, height: 720)

        Window("Battery details", id: BatteryDetailsView.windowID) {
            BatteryDetailsView()
                .environment(monitor)
        }
        .defaultSize(width: 720, height: 720)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}
