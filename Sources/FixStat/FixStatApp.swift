import SwiftUI

@main
struct FixStatApp: App {
    @State private var monitor: Monitor
    @State private var testRunner: TestRunner
    @State private var ssdRunner: SSDTestRunner
    @State private var memoryRunner: MemoryTestRunner
    @State private var fullSSDRunner: FullSSDTestRunner

    init() {
        let monitor = Monitor()
        _monitor = State(initialValue: monitor)
        _testRunner = State(initialValue: TestRunner(monitor: monitor))
        _ssdRunner = State(initialValue: SSDTestRunner(monitor: monitor))
        _memoryRunner = State(initialValue: MemoryTestRunner(monitor: monitor))
        _fullSSDRunner = State(initialValue: FullSSDTestRunner(monitor: monitor))
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

        Window("Memory test", id: MemoryView.windowID) {
            MemoryView()
                .environment(memoryRunner)
        }
        .defaultSize(width: 600, height: 480)

        Window("SSD", id: SSDView.windowID) {
            SSDView()
                .environment(ssdRunner)
                .environment(fullSSDRunner)
        }
        .defaultSize(width: 660, height: 720)

        Window("Device info", id: DeviceInfoView.windowID) {
            DeviceInfoView()
                .environment(monitor)
        }
        .defaultSize(width: 620, height: 680)

        Window("Hardware check", id: HardwareCheckView.windowID) {
            HardwareCheckView()
                .environment(monitor)
        }
        .defaultSize(width: 900, height: 680)

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
