import Foundation
import MacSensors
import Observation

/// One temperature sensor as shown in the UI.
struct DisplaySensor: Identifiable, Equatable {
    let descriptor: SensorDescriptor
    let resolved: ResolvedSensor?

    var id: String { descriptor.uid }
    var isMatched: Bool { resolved != nil }
    var isModelMatch: Bool { resolved?.level == .model }
    var isEstimated: Bool { resolved?.confidence != .verified }
    var group: SensorMap.Group { resolved?.group ?? .other }
    var name: String { SensorNames.name(for: self) }
}

/// Polls all data sources and publishes the latest values.
///
/// Values are always assigned as whole Equatable values so that SwiftUI only
/// invalidates views whose data actually changed.
@MainActor
@Observable
final class Monitor {
    let system = SystemInfo.current()
    private(set) var sensors: [DisplaySensor] = []
    /// Sensor uid → °C.
    private(set) var values: [String: Double] = [:]
    private(set) var battery: BatteryInfo?
    private(set) var fans: [FanReading] = []
    private(set) var cpuUsage: Double?
    private(set) var memory: SystemStats.Memory?
    private(set) var map = SensorMap()
    /// Reference data of genuine batteries and adapters (`parts.json`).
    let partsReference: PartsReference = {
        let url = Bundle.main.url(forResource: "parts", withExtension: "json")
            ?? URL(fileURLWithPath: "SensorMaps/parts.json")
        return (try? PartsReference.load(from: url)) ?? PartsReference()
    }()

    /// While the panel is open, everything is refreshed at the configured
    /// interval. Otherwise only what the menu bar shows, and at most every 5 s.
    var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            refresh()
            scheduleTimer()
        }
    }

    /// While a stress test runs, the test drives full refreshes itself.
    var testRunning = false {
        didSet { scheduleTimer() }
    }

    /// Result of the last post-repair test (for reports).
    var lastTestResult: StressTestResult?
    /// Result of the last memory test (for reports).
    var lastMemoryResult: MemoryTest.Result?
    /// Last panic / shutdown cause scan (for reports).
    var lastCrashScan: CrashScan?
    /// Result of the last full SSD test (for reports).
    var lastFullSSDResult: FullSSDTestRunner.Result?
    /// Result of the last SSD write–verify test (for reports).
    var lastSSDResult: SSDStressTest.Result?

    /// The battery details window refreshes the battery at the panel's rate.
    var detailsVisible = false {
        didSet {
            guard detailsVisible != oldValue else { return }
            refresh()
            scheduleTimer()
        }
    }

    @ObservationIgnored private var sampler: TemperatureSampler?
    @ObservationIgnored private let stats = SystemStats()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var lastInterval = 0.0
    @ObservationIgnored let history: BatteryHistoryStore
    @ObservationIgnored private let alerts = AlertManager()
    @ObservationIgnored private var lastHistorySample = Date.distantPast
    @ObservationIgnored private var lastPrune = Date.distantPast
    /// Seconds between two battery history samples.
    static let historyInterval: TimeInterval = 60

    init() {
        Pref.register()
        history = BatteryHistoryStore(directory: Self.dataDirectory)
        loadMap()
        buildSensors()
        refresh()
        scheduleTimer()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleTimer()
                AppearancePreference.apply()
            }
        }
        DispatchQueue.main.async { AppearancePreference.apply() }
    }

    // MARK: - Sensor map

    /// ~/Library/Application Support/FixStat, or the directory passed with
    /// `--data-dir` (used for UI checks with sample data).
    static var dataDirectory: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FixStat", isDirectory: true)
    }

    static var userMapURL: URL {
        dataDirectory.appendingPathComponent("sensor-map.json")
    }

    static var bundledMapURL: URL? {
        Bundle.main.url(forResource: "sensor-map", withExtension: "json")
            ?? {
                // Development fallback when run outside the app bundle.
                let url = URL(fileURLWithPath: "SensorMaps/sensor-map.json")
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }()
    }

    private func loadMap() {
        var result = Self.bundledMapURL.flatMap { try? SensorMap.load(from: $0) } ?? SensorMap()
        if let user = try? SensorMap.load(from: Self.userMapURL) {
            result = result.merged(with: user)
        }
        map = result
    }

    private func buildSensors() {
        let model = system.model
        let map = self.map
        // Only SMC keys that are not known to be derived or meaningless; HID is one call anyway.
        let sampler = TemperatureSampler { key in
            !map.isIgnored(key: key, hidName: nil, model: model)
        }
        self.sampler = sampler
        sensors = sampler.sensors
            .filter { !map.isIgnored(key: $0.key, hidName: $0.hidName, model: model) }
            .map { descriptor in
                DisplaySensor(descriptor: descriptor,
                              resolved: map.resolve(key: descriptor.key, hidName: descriptor.hidName,
                                                    model: model, chip: system.chip))
            }
    }

    /// Stores a user-defined name (or removes it when `name` is empty) in the
    /// user's sensor map and reloads.
    func rename(_ sensor: DisplaySensor, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var user = (try? SensorMap.load(from: Self.userMapURL)) ?? SensorMap()
        var model = user.models[system.model]
            ?? SensorMap.ModelMap(chip: system.chip, board: system.boardTarget, description: nil, sensors: [], ignored: nil)
        let key = sensor.descriptor.rawLabel
        model.sensors.removeAll { $0.key == key }
        if !trimmed.isEmpty {
            model.sensors.append(.init(
                key: key,
                id: sensor.resolved?.id ?? "user.\(key)",
                group: sensor.resolved?.group ?? .other,
                confidence: sensor.resolved?.confidence ?? .estimated,
                hidName: sensor.descriptor.hidName,
                name: trimmed
            ))
        }
        user.models[system.model] = model
        do {
            try FileManager.default.createDirectory(at: Self.userMapURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(user).write(to: Self.userMapURL)
        } catch {
            NSLog("FixStat: cannot save user sensor map: \(error)")
        }
        loadMap()
        buildSensors()
        refresh()
    }

    // MARK: - Polling

    private var configuredInterval: Double {
        let value = UserDefaults.standard.double(forKey: Pref.updateInterval)
        return value > 0 ? value : Pref.defaultInterval
    }

    private func scheduleTimer() {
        let interval = panelVisible || detailsVisible ? configuredInterval : max(configuredInterval, 5)
        guard interval != lastInterval || timer == nil else { return }
        lastInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let defaults = UserDefaults.standard
        let now = Date()
        let historyDue = now.timeIntervalSince(lastHistorySample) >= Self.historyInterval
        let needsBattery = panelVisible || detailsVisible || testRunning || historyDue || AlertManager.enabled || defaults.bool(forKey: Pref.menuBarBatteryIcon)
            || defaults.bool(forKey: Pref.menuBarBatteryPercent)
        if needsBattery {
            let latest = BatteryReader.read()
            if latest != battery { battery = latest }
            if historyDue, let latest {
                history.record(latest, at: now)
                lastHistorySample = now
                if now.timeIntervalSince(lastPrune) > 24 * 3600 {
                    history.prune(now: now)
                    lastPrune = now
                }
            }
        }

        guard let sampler else { return }
        if panelVisible || testRunning {
            var latest: [String: Double] = [:]
            for (sensor, value) in zip(sampler.sensors, sampler.sample()) {
                if let value { latest[sensor.uid] = value }
            }
            values = latest.mapValues { ($0 * 10).rounded() / 10 }
            let latestFans = sampler.fans()
            if latestFans != fans { fans = latestFans }
            cpuUsage = stats.cpuUsage().map { ($0 * 1000).rounded() / 1000 }
            memory = stats.memory()
        } else if defaults.bool(forKey: Pref.menuBarCPUTemperature) || AlertManager.enabled {
            // HID only: covers the CPU cluster sensors on Apple Silicon in one call.
            var latest = values
            for (uid, value) in sampler.sampleHID() {
                latest[uid] = (value * 10).rounded() / 10
            }
            values = latest
        }
        alerts.evaluate(monitor: self)
    }

    // MARK: - Derived values

    /// Value of a sensor if it is plausible.
    func value(of sensor: DisplaySensor) -> Double? {
        guard let value = values[sensor.id], SMC.plausibleTemperatureRange.contains(value) else { return nil }
        return value
    }

    /// Hottest CPU sensor (cluster zones on Apple Silicon, cores/die on Intel).
    var cpuTemperature: Double? {
        sensors.filter { $0.group == .cpu }.compactMap(value(of:)).max()
    }

    /// Maximum over sensors whose id starts with one of the prefixes.
    func maximum(idPrefixes: [String], excluding hidden: Set<String>) -> Double? {
        sensors
            .filter { sensor in
                !hidden.contains(sensor.id)
                    && idPrefixes.contains { sensor.resolved?.id.hasPrefix($0) == true }
            }
            .compactMap(value(of:))
            .max()
    }
}
