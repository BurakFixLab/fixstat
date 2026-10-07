import Foundation
import MacSensors
import Observation
import FixStatCore

/// SwiftUI view of `MonitorCore`: publishes its latest values through Observation
/// and keeps the session's test results for reports.
@available(macOS 14.0, *)
@MainActor
@Observable
final class Monitor {
    /// Polling and all data sources, shared with the AppKit interface.
    @ObservationIgnored let core: MonitorCore

    var system: SystemInfo { core.system }
    var partsReference: PartsReference { core.partsReference }
    var history: BatteryHistoryStore { core.history }
    private(set) var sensors: [DisplaySensor] = []
    /// Sensor uid → °C.
    private(set) var values: [String: Double] = [:]
    private(set) var battery: BatteryInfo?
    private(set) var fans: [FanReading] = []
    private(set) var cpuUsage: Double?
    private(set) var memory: SystemStats.Memory?
    private(set) var map = SensorMap()

    /// While the panel is open, everything is refreshed at the configured
    /// interval. Otherwise only what the menu bar shows, and at most every 5 s.
    var panelVisible = false {
        didSet { core.panelVisible = panelVisible }
    }

    /// The battery details window refreshes the battery at the panel's rate.
    var detailsVisible = false {
        didSet { core.detailsVisible = detailsVisible }
    }


    // Session results kept in the core (both interfaces read them), observed here.
    /// Hardware checklist of this session (for reports).
    /// Notebook, iMac or desktop: decides which tools and checks are offered.
    var profile: HardwareProfile { core.profile }

    func resetHardwareCheck() {
        withMutation(keyPath: \.usbSpeedResults) {
            withMutation(keyPath: \.hardwareCheck) { core.resetHardwareCheck() }
        }
    }

    var hardwareCheck: HardwareCheck {
        get { access(keyPath: \.hardwareCheck); return core.hardwareCheck }
        set { withMutation(keyPath: \.hardwareCheck) { core.hardwareCheck = newValue } }
    }
    /// Device card data (system_profiler takes about a second, so it is loaded on demand).
    var deviceInfo: DeviceInfo? {
        get { access(keyPath: \.deviceInfo); return core.deviceInfo }
        set { withMutation(keyPath: \.deviceInfo) { core.deviceInfo = newValue } }
    }
    /// Last panic / shutdown cause scan (for reports).
    var lastCrashScan: CrashScan? {
        get { access(keyPath: \.lastCrashScan); return core.lastCrashScan }
        set { withMutation(keyPath: \.lastCrashScan) { core.lastCrashScan = newValue } }
    }
    /// Last sleep / wake analysis (for reports).
    var lastSleepAnalysis: SleepAnalysis? {
        get { access(keyPath: \.lastSleepAnalysis); return core.lastSleepAnalysis }
        set { withMutation(keyPath: \.lastSleepAnalysis) { core.lastSleepAnalysis = newValue } }
    }
    /// Result of the last post-repair test (for reports).
    var lastTestResult: StressTestResult? {
        get { access(keyPath: \.lastTestResult); return core.lastTestResult }
        set { withMutation(keyPath: \.lastTestResult) { core.lastTestResult = newValue } }
    }
    /// Result of the last memory test (for reports).
    var lastMemoryResult: MemoryTest.Result? {
        get { access(keyPath: \.lastMemoryResult); return core.lastMemoryResult }
        set { withMutation(keyPath: \.lastMemoryResult) { core.lastMemoryResult = newValue } }
    }
    /// Result of the last SSD write–verify test (for reports).
    /// USB drive speed tests of this session (ports check).
    var usbSpeedResults: [USBSpeedResult] {
        get { access(keyPath: \.usbSpeedResults); return core.usbSpeedResults }
        set { withMutation(keyPath: \.usbSpeedResults) { core.usbSpeedResults = newValue } }
    }
    var lastSSDResult: SSDStressTest.Result? {
        get { access(keyPath: \.lastSSDResult); return core.lastSSDResult }
        set { withMutation(keyPath: \.lastSSDResult) { core.lastSSDResult = newValue } }
    }
    /// Result of the last full SSD test (for reports).
    var lastFullSSDResult: FullSSDResult? {
        get { access(keyPath: \.lastFullSSDResult); return core.lastFullSSDResult }
        set { withMutation(keyPath: \.lastFullSSDResult) { core.lastFullSSDResult = newValue } }
    }
    /// Result of the last battery capacity test (for reports).
    var lastCapacityResult: CapacityResult? {
        get { access(keyPath: \.lastCapacityResult); return core.lastCapacityResult }
        set { withMutation(keyPath: \.lastCapacityResult) { core.lastCapacityResult = newValue } }
    }

    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    static var dataDirectory: URL { MonitorCore.dataDirectory }
    static var userMapURL: URL { MonitorCore.userMapURL }
    static var historyInterval: TimeInterval { MonitorCore.historyInterval }

    init() {
        AlertManager.installUserNotificationSender()
        core = MonitorCore()
        core.onUpdate = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppearancePreference.apply() }
        }
        DispatchQueue.main.async { AppearancePreference.apply() }
    }

    /// Copies the core's values, assigning only what changed so SwiftUI only
    /// invalidates views whose data actually changed.
    private func sync() {
        if core.sensors != sensors { sensors = core.sensors }
        if core.values != values { values = core.values }
        if core.battery != battery { battery = core.battery }
        if core.fans != fans { fans = core.fans }
        if core.cpuUsage != cpuUsage { cpuUsage = core.cpuUsage }
        if core.memory != memory { memory = core.memory }
        if core.map != map { map = core.map }
    }

    func offPeriods(_ analysis: SleepAnalysis) -> [OffPeriod] {
        core.offPeriods(analysis)
    }

    func loadDeviceInfo() async {
        deviceInfo = await withCheckedContinuation { continuation in
            MonitorCore.loadDeviceInfo { continuation.resume(returning: $0) }
        }
    }

    func rename(_ sensor: DisplaySensor, to name: String) {
        core.rename(sensor, to: name)
    }

    func refresh() {
        core.refresh()
    }

    // MARK: - Derived values (read the observed copies)

    /// Value of a sensor if it is plausible.
    func value(of sensor: DisplaySensor) -> Double? {
        MonitorCore.value(of: sensor, in: values)
    }

    /// Hottest CPU sensor (cluster zones on Apple Silicon, cores/die on Intel).
    var cpuTemperature: Double? {
        MonitorCore.cpuTemperature(sensors: sensors, values: values)
    }

    /// Maximum over sensors whose id starts with one of the prefixes.
    func maximum(idPrefixes: [String], excluding hidden: Set<String>) -> Double? {
        MonitorCore.maximum(sensors: sensors, values: values, idPrefixes: idPrefixes, excluding: hidden)
    }
}
