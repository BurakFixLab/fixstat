import Foundation
import MacSensors

/// Polls all data sources (battery, temperatures, fans, CPU, memory) for both interfaces.
///
/// Runs on the main thread without Swift concurrency, so it also works on macOS 10.13.
/// The SwiftUI `Monitor` and the AppKit interface subscribe with `onUpdate`, which is
/// called after every refresh; values are only replaced when they changed.
public final class MonitorCore {
    public let system = SystemInfo.current()
    /// Notebook, iMac or desktop and its built-in parts: decides which tools and checks apply.
    public let profile: HardwareProfile
    public private(set) var sensors: [DisplaySensor] = []
    /// Sensor uid → °C.
    public private(set) var values: [String: Double] = [:]
    public private(set) var battery: BatteryInfo?
    public private(set) var fans: [FanReading] = []
    public private(set) var cpuUsage: Double?
    public private(set) var memory: SystemStats.Memory?
    public private(set) var map = SensorMap()
    /// Reference data of genuine batteries and adapters (`parts.json`).
    public let partsReference: PartsReference = {
        let url = Bundle.main.url(forResource: "parts", withExtension: "json")
            ?? URL(fileURLWithPath: "SensorMaps/parts.json")
        return (try? PartsReference.load(from: url)) ?? PartsReference()
    }()
    /// Idle power with the display off of good Macs per model (`power-reference.json`).
    public let powerReference: PowerReference = {
        let url = Bundle.main.url(forResource: "power-reference", withExtension: "json")
            ?? URL(fileURLWithPath: "SensorMaps/power-reference.json")
        return PowerReference.load(from: url) ?? PowerReference()
    }()
    /// Result of the last idle power measurement (session, for reports).
    public var lastIdlePower: IdlePowerResult?

    /// Called on the main thread after each refresh and after the sensor list changed.
    public var onUpdate: (() -> Void)?

    /// While the panel is open, everything is refreshed at the configured
    /// interval. Otherwise only what the menu bar shows, and at most every 5 s.
    public var panelVisible = false {
        didSet {
            guard panelVisible != oldValue else { return }
            refresh()
            scheduleTimer()
        }
    }

    /// The battery details window refreshes the battery at the panel's rate.
    public var detailsVisible = false {
        didSet {
            guard detailsVisible != oldValue else { return }
            refresh()
            scheduleTimer()
        }
    }

    /// While a stress test runs, the test drives full refreshes itself.
    public var testRunning = false {
        didSet { scheduleTimer() }
    }

    // Session results (for reports), shared by both interfaces.
    /// Hardware checklist of this session.
    public var hardwareCheck: HardwareCheck
    /// Called after `recordCheck` changed the checklist (the AppKit window updates its list).
    public var onHardwareCheckChange: (() -> Void)?

    /// Clears every mark of the hardware check.
    public func resetHardwareCheck() {
        hardwareCheck = HardwareCheck(profile: profile)
    }
    /// Device card data (system_profiler takes about a second, so it is loaded on demand).
    public var deviceInfo: DeviceInfo?
    /// Last panic / shutdown cause scan.
    public var lastCrashScan: CrashScan?
    /// Last sleep / wake analysis.
    public var lastSleepAnalysis: SleepAnalysis?
    /// Result of the last post-repair test.
    public var lastTestResult: StressTestResult?
    /// Result of the last memory test.
    public var lastMemoryResult: MemoryTest.Result?
    /// Result of the last SSD write–verify test.
    public var lastSSDResult: SSDStressTest.Result?
    /// Result of the last full SSD test.
    public var lastFullSSDResult: FullSSDResult?
    /// Result of the last battery capacity test.
    public var lastCapacityResult: CapacityResult?

    public let history: BatteryHistoryStore
    public private(set) var offState: OffStateRecorder?
    /// Gauge snapshots around sleeps (notebooks with a battery).
    public private(set) var drainRecorder: DrainRecorder?

    /// Drain detective over the measured sleeps and shutdowns; `analysis` adds the dark
    /// wakes and settings from the power log.
    public func drainReport(analysis: SleepAnalysis?) -> DrainReport {
        DrainReport.make(segments: DrainRecorder.load(from: Self.dataDirectory) + Self.sampleDrainSegments(), analysis: analysis)
    }

    /// `-FixStatSampleDrain YES`: a made-up night (high drain asleep, normal shut down) for
    /// checking the screens.
    static func sampleDrainSegments() -> [DrainSegment] {
        guard UserDefaults.standard.bool(forKey: "FixStatSampleDrain") else { return [] }
        let night = Date().addingTimeInterval(-86_400)
        func snapshot(_ date: Date, _ remaining: Int) -> GaugeSnapshot {
            GaugeSnapshot(date: date, remaining: remaining, charge: nil, externalConnected: false, isCharging: false,
                          cellQmax: nil, cellDOD0: nil, cellVoltages: nil)
        }
        return [DrainSegment(kind: .sleep, start: snapshot(night, 3000), end: snapshot(night.addingTimeInterval(8 * 3600), 2440)),
                DrainSegment(kind: .off, start: snapshot(night.addingTimeInterval(10 * 3600), 2400),
                             end: snapshot(night.addingTimeInterval(20 * 3600), 2370))]
    }
    private var sampler: TemperatureSampler?
    private var dieSMCKeys: [String] = []
    private let stats = SystemStats()
    private var timer: Timer?
    private var defaultsObserver: NSObjectProtocol?
    private var lastInterval = 0.0
    private let alerts = AlertManager()
    private var lastHistorySample = Date.distantPast
    private var lastPrune = Date.distantPast
    /// Seconds between two battery history samples.
    public static let historyInterval: TimeInterval = 60

    public init() {
        profile = HardwareProfile.current(system: system)
        hardwareCheck = HardwareCheck(profile: profile)
        Pref.register()
        history = BatteryHistoryStore(directory: Self.dataDirectory)
        if !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--export") {
            offState = OffStateRecorder(directory: Self.dataDirectory)
            IdlePowerRunner.restoreAfterCrash()
            if profile.hasBattery { drainRecorder = DrainRecorder(directory: Self.dataDirectory) }
            // Judged from the battery charge before the shutdown: notebooks only.
            if profile.hasBattery { UnexpectedShutdown.checkAtLaunch() }
        }
        loadMap()
        let interactive = !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--export")
        buildSensors(inBackground: interactive)
        refresh()
        scheduleTimer()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleTimer()
        }
    }

    deinit {
        timer?.invalidate()
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
    }

    /// Shut-down periods: measured by FixStat where available, otherwise from the power log.
    public func offPeriods(_ analysis: SleepAnalysis) -> [OffPeriod] {
        let measured = offState?.periods ?? []
        let fromLog = analysis.offPeriods.filter { log in
            !measured.contains { abs($0.boot.timeIntervalSince(log.boot)) < 120 }
        }
        return (measured + fromLog).sorted { $0.boot < $1.boot }
    }

    /// Reads the device card in the background (system_profiler takes about a second).
    public static func loadDeviceInfo(completion: @escaping (DeviceInfo) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let info = DeviceInfo.read()
            DispatchQueue.main.async { completion(info) }
        }
    }

    // MARK: - Sensor map

    /// ~/Library/Application Support/FixStat, or the directory passed with
    /// `--data-dir` (used for UI checks with sample data).
    public static var dataDirectory: URL {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FixStat", isDirectory: true)
    }

    public static var userMapURL: URL {
        dataDirectory.appendingPathComponent("sensor-map.json")
    }

    public static var bundledMapURL: URL? {
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

    /// Enumerating the SMC (≈ 1500 keys, then every temperature key) takes seconds on older
    /// Intel Macs, so at launch it runs in the background; snapshots and exports need the
    /// sensors right away.
    private func buildSensors(inBackground: Bool = false) {
        let model = system.model
        let chip = system.chip
        let map = self.map
        // Only SMC keys that are not known to be derived or meaningless; HID is one call anyway.
        let make = {
            TemperatureSampler { key in
                !map.isIgnored(key: key, hidName: nil, model: model, chip: chip)
            }
        }
        guard inBackground else {
            install(make(), map: map)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sampler = make()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.install(sampler, map: map)
                self.refresh()
            }
        }
    }

    private func install(_ sampler: TemperatureSampler, map: SensorMap) {
        let model = system.model
        let chip = system.chip
        self.sampler = sampler
        sensors = sampler.sensors
            .filter { !map.isIgnored(key: $0.key, hidName: $0.hidName, model: model, chip: chip) }
            .map { descriptor in
                DisplaySensor(descriptor: descriptor,
                              resolved: map.resolve(key: descriptor.key, hidName: descriptor.hidName,
                                                    model: model, chip: chip))
            }
        // Read while the panel is closed too (menu bar CPU temperature, chip alert): Intel and
        // Apple Silicon after M1 have their die sensors only in the SMC.
        dieSMCKeys = sensors
            .filter { ($0.group == .cpu || $0.group == .gpu) && $0.descriptor.source == .smc }
            .compactMap(\.descriptor.key)
    }

    /// Stores a user-defined name (or removes it when `name` is empty) in the
    /// user's sensor map and reloads.
    public func rename(_ sensor: DisplaySensor, to name: String) {
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
            NSLog("FixStat: cannot save user sensor map: %@", "\(error)")
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
            self?.refresh()
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// `-FixStatSampleCells 300,3600,3600`: made-up cell voltages (mV) for checking how the
    /// panels show a dead or drifting cell. Not written to the battery history.
    static let sampledCells: [Int]? = UserDefaults.standard.string(forKey: "FixStatSampleCells")
        .map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        .flatMap { $0.isEmpty ? nil : $0 }
    static var samplingCells: Bool { sampledCells != nil }

    static func sampleCells(_ info: BatteryInfo) -> BatteryInfo {
        guard let cells = sampledCells else { return info }
        var info = info
        info.cellVoltages = cells
        info.cellImbalance = (cells.max() ?? 0) - (cells.min() ?? 0)
        return info
    }

    public func refresh() {
        let defaults = UserDefaults.standard
        let now = Date()
        let historyDue = now.timeIntervalSince(lastHistorySample) >= Self.historyInterval
        let needsBattery = panelVisible || detailsVisible || testRunning || historyDue || AlertManager.enabled
            || defaults.bool(forKey: Pref.menuBarBatteryIcon) || defaults.bool(forKey: Pref.menuBarBatteryPercent)
        if needsBattery {
            let latest = profile.hasBattery ? BatteryReader.read().map(Self.sampleCells) : nil
            if latest != battery { battery = latest }
            if historyDue, let latest, !Self.samplingCells {
                history.record(latest, at: now)
                lastHistorySample = now
                if now.timeIntervalSince(lastPrune) > 24 * 3600 {
                    history.prune(now: now)
                    lastPrune = now
                }
            }
        }

        if let sampler {
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
                // HID (one call) plus the CPU / GPU sensors that only the SMC has.
                var latest = values
                for (uid, value) in sampler.sampleHID().merging(sampler.sampleSMC(keys: dieSMCKeys), uniquingKeysWith: { a, _ in a }) {
                    latest[uid] = (value * 10).rounded() / 10
                }
                values = latest
            }
            alerts.evaluate(monitor: self)
        }
        onUpdate?()
    }

    // MARK: - Derived values

    /// Value of a sensor if it is plausible.
    public func value(of sensor: DisplaySensor) -> Double? {
        Self.value(of: sensor, in: values)
    }

    /// Hottest CPU sensor (cluster zones on Apple Silicon, cores/die on Intel).
    public var cpuTemperature: Double? {
        Self.cpuTemperature(sensors: sensors, values: values)
    }

    public static func value(of sensor: DisplaySensor, in values: [String: Double]) -> Double? {
        guard let value = values[sensor.id], SMC.plausibleTemperatureRange.contains(value) else { return nil }
        // A power-gated Apple Silicon cluster reads 0 or its calibration offset: no reading.
        if sensor.group == .cpu || sensor.group == .gpu, value < SMC.minimumActiveDieTemperature { return nil }
        return value
    }

    public static func cpuTemperature(sensors: [DisplaySensor], values: [String: Double]) -> Double? {
        sensors.filter { $0.group == .cpu }.compactMap { value(of: $0, in: values) }.max()
    }

    /// Maximum over sensors whose id starts with one of the prefixes.
    public static func maximum(sensors: [DisplaySensor], values: [String: Double],
                               idPrefixes: [String], excluding hidden: Set<String>) -> Double? {
        sensors
            .filter { sensor in
                !hidden.contains(sensor.id)
                    && idPrefixes.contains { sensor.resolved?.id.hasPrefix($0) == true }
            }
            .compactMap { value(of: $0, in: values) }
            .max()
    }
}

extension MonitorCore {
    /// Stores measured evidence; marks the item passed (or failed, for a clear measured fault)
    /// if nothing was marked yet (the technician's own choice is never overridden).
    public func recordCheck(_ item: HardwareCheck.Item, detail: String, passed: Bool = false, failed: Bool = false) {
        hardwareCheck[item].detail = detail
        if passed || failed, hardwareCheck[item].status == .untested {
            hardwareCheck[item].status = passed ? .passed : .failed
            hardwareCheck[item].date = Date()
        }
        onHardwareCheckChange?()
    }
}
