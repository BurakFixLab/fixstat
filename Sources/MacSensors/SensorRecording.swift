import Foundation

/// A recorded sensor session: samples plus the phases they belong to.
public struct SensorRecording: Codable, Sendable {
    public struct Phase: Codable, Sendable {
        /// "baseline", "single", "all", "gpu", "ssd", "unplugged", "charging", "cooldown"
        public var name: String
        public var start: Double
        public var end: Double
    }

    public struct Sample: Codable, Sendable {
        /// Seconds since the start of the recording.
        public var t: Double
        public var values: [Double?]
        public var batteryAmperage: Int?
        public var externalConnected: Bool?
        /// Fan speeds in rpm (empty on fanless Macs; nil in older recordings).
        public var fans: [Double]?
        /// The speed the SMC asks of each fan (`F<n>Tg`), same order as `fans`; nil in older
        /// recordings. A fan far above its target is out of the SMC's control.
        public var fanTargets: [Double?]?
        /// Adapter input power in W (`SystemPowerIn`, Apple Silicon notebooks on power).
        public var powerIn: Double?
        /// System power in W without battery charging (input − charging − adapter loss, or
        /// what the battery delivers on battery).
        public var systemPower: Double?
        /// The SMC's total system power (`PSTR`, W), updated every second.
        public var smcPower: Double?
        /// User and system shares of all CPUs (0…1), and the share this process used.
        public var cpuUser: Double?
        public var cpuSystem: Double?
        public var ownCPU: Double?
    }

    public var tool = "sensormap"
    public var version = MacSensors.version
    public var system: SystemInfo
    public var startedAt: Date
    public var sensors: [SensorDescriptor]
    public var phases: [Phase] = []
    public var samples: [Sample] = []
    /// Each fan's minimum and maximum speed (`F<n>Mn` / `F<n>Mx`); nil in older recordings.
    public var fanMinimum: [Double?]?
    public var fanMaximum: [Double?]?
}

/// Drives the load tests and collects samples once per second.
public final class SensorRecorder {
    public let sampler = TemperatureSampler()
    public var recording: SensorRecording
    private let start = Date()
    public let interval: TimeInterval
    /// Progress lines (e.g. printed to stderr by the command-line tools).
    public var progress: (String) -> Void = { _ in }
    /// Called after every sample (e.g. to show live values).
    public var onSample: (SensorRecording.Sample) -> Void = { _ in }
    /// Checked once per second; ends the current phase early when true.
    public var isCancelled: () -> Bool = { false }
    /// Sensors that count for `hotMean`, by index (nil: all). Leave out keys a sensor map
    /// hides: aggregates such as the M1's `Tp8z` read values far above the real dies.
    private var hotMeanIndices: Set<Int>?

    /// Only sensors for which `include` returns true count for `hotMean`.
    public func setHotMeanFilter(_ include: (SensorDescriptor) -> Bool) {
        hotMeanIndices = Set(recording.sensors.indices.filter { include(recording.sensors[$0]) })
    }

    public init(interval: TimeInterval = 1) {
        self.interval = interval
        recording = SensorRecording(system: .current(), startedAt: Date(), sensors: sampler.sensors)
        let fans = sampler.fans()
        if !fans.isEmpty {
            recording.fanMinimum = fans.map(\.minimum)
            recording.fanMaximum = fans.map(\.maximum)
        }
    }

    public var now: Double { Date().timeIntervalSince(start) }

    private let stats = SystemStats()
    private var lastOwnCPU: (time: Double, at: Date)?

    public func takeSample() {
        let battery = BatteryReader.read()
        let input = battery?.powerTelemetry?.systemPowerIn.flatMap { $0 > 0 ? Double($0) / 1000 : nil }
        let load = stats.cpuLoad()
        let ownTime = SystemStats.ownCPUTime(), date = Date()
        var own: Double?
        if let last = lastOwnCPU, date > last.at {
            own = (ownTime - last.time) / date.timeIntervalSince(last.at) / Double(ProcessInfo.processInfo.activeProcessorCount)
        }
        lastOwnCPU = (ownTime, date)
        let fanReadings = sampler.fans()
        var sample = SensorRecording.Sample(t: now, values: sampler.sample(),
                                            batteryAmperage: battery?.amperage,
                                            externalConnected: battery?.externalConnected,
                                            fans: fanReadings.compactMap(\.actual),
                                            powerIn: input,
                                            systemPower: battery?.systemPowerWatts.map { ($0 * 100).rounded() / 100 },
                                            smcPower: sampler.systemPower().map { ($0 * 100).rounded() / 100 },
                                            cpuUser: load.map { ($0.user * 1000).rounded() / 1000 },
                                            cpuSystem: load.map { ($0.system * 1000).rounded() / 1000 },
                                            ownCPU: own.map { (min(1, $0) * 1000).rounded() / 1000 })
        if !fanReadings.isEmpty { sample.fanTargets = fanReadings.map(\.target) }
        recording.samples.append(sample)
        onSample(sample)
    }

    /// Samples for `duration` seconds and records the span as a phase.
    public func phase(_ name: String, duration: TimeInterval, until stop: (() -> Bool)? = nil) {
        let phaseStart = now
        let deadline = Date().addingTimeInterval(duration)
        var lastLog = Date.distantPast
        while Date() < deadline {
            let tick = Date()
            takeSample()
            if stop?() == true || isCancelled() { break }
            if Date().timeIntervalSince(lastLog) >= 10 {
                progress("  \(name): \(Int(now - phaseStart)) s, mean HID \(SensorMapReport.fmt(meanHID(recording.samples.last)))")
                lastLog = Date()
            }
            let elapsed = Date().timeIntervalSince(tick)
            if elapsed < interval { Thread.sleep(forTimeInterval: interval - elapsed) }
        }
        recording.phases.append(.init(name: name, start: phaseStart, end: now))
    }

    /// Cools down until the hot mean (see `hotMean`) is within `tolerance` of `target`,
    /// bounded by `minimum` and `maximum` seconds.
    public func cooldown(to target: Double?, tolerance: Double = 1.0, minimum: TimeInterval, maximum: TimeInterval) {
        let begin = Date()
        phase("cooldown", duration: maximum) { [self] in
            guard Date().timeIntervalSince(begin) >= minimum else { return false }
            guard let target, let current = recentHotMean(seconds: 5) else { return true }
            return current <= target + tolerance
        }
    }

    /// Runs a phase for at least `minimum` seconds and ends it once the temperatures stop
    /// rising (the hot mean changed less than `tolerance` °C over the last `window`
    /// seconds), at the latest after `maximum` seconds.
    public func plateauPhase(_ name: String, minimum: TimeInterval, maximum: TimeInterval,
                             window: TimeInterval = 30, tolerance: Double = 0.5) {
        let begin = Date()
        phase(name, duration: maximum) { [self] in
            guard Date().timeIntervalSince(begin) >= max(minimum, window) else { return false }
            return isPlateau(window: window, tolerance: tolerance)
        }
    }

    /// The hot mean changed less than `tolerance` between the start and the end of the
    /// last `window` seconds (5 s averages at both ends).
    public func isPlateau(window: TimeInterval, tolerance: Double) -> Bool {
        let end = now
        func mean(from: Double, to: Double) -> Double? {
            let values = recording.samples.filter { $0.t >= from && $0.t <= to }.compactMap { hotMean($0) }
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        guard let first = mean(from: end - window, to: end - window + 5), let last = mean(from: end - 5, to: end)
        else { return false }
        return abs(last - first) < tolerance
    }

    /// Mean of the `count` hottest plausible readings of a sample (all sources). Follows
    /// the dies on every Mac: Intel and Apple Silicon after M1 have no die sensors in HID.
    /// Readings below `SMC.minimumActiveDieTemperature` (power-gated zones) are left out.
    public func hotMean(_ sample: SensorRecording.Sample?, count: Int = 8) -> Double? {
        guard let sample else { return nil }
        let values = sample.values.enumerated().compactMap { index, value -> Double? in
            guard hotMeanIndices?.contains(index) ?? true,
                  let value, SMC.plausibleTemperatureRange.contains(value),
                  value >= SMC.minimumActiveDieTemperature else { return nil }
            return value
        }.sorted(by: >).prefix(count)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Hot mean over the last `seconds` of samples.
    public func recentHotMean(seconds: Double = 10) -> Double? {
        let cutoff = now - seconds
        let values = recording.samples.filter { $0.t >= cutoff }.compactMap { hotMean($0) }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Mean over plausible HID sensor values of one sample.
    public func meanHID(_ sample: SensorRecording.Sample?) -> Double? {
        guard let sample else { return nil }
        let values = zip(recording.sensors, sample.values).compactMap { sensor, value -> Double? in
            guard sensor.source == .hid, let value, SMC.plausibleTemperatureRange.contains(value) else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Mean HID temperature over the last `seconds` of samples.
    public func recentMeanHID(seconds: Double = 10) -> Double? {
        let cutoff = now - seconds
        let values = recording.samples.filter { $0.t >= cutoff }.compactMap(meanHID)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

/// The load tests of a sensor recording, shared by `sensormap` and other tools.
public enum SensorLoadTests {
    public static let loadTests: Set<String> = ["single", "all", "gpu", "ssd"]

    public struct Plan: Sendable {
        public var tests: [String]
        public var duration: TimeInterval
        public var baseline: TimeInterval
        public var cooldownMinimum: TimeInterval
        public var cooldownMaximum: TimeInterval

        public init(tests: [String], duration: TimeInterval, baseline: TimeInterval,
                    cooldownMinimum: TimeInterval = 20, cooldownMaximum: TimeInterval = 120) {
            self.tests = tests
            self.duration = duration
            self.baseline = baseline
            self.cooldownMinimum = cooldownMinimum
            self.cooldownMaximum = cooldownMaximum
        }

        /// About 9 minutes: every load test, 45 s each.
        public static let full = Plan(tests: ["single", "all", "gpu", "ssd"], duration: 45, baseline: 30)
        /// About 3 minutes: all cores, GPU and SSD, 30 s each, short cooldowns. Enough to
        /// verify CPU (all), GPU and SSD sensors; single-core zones stay less certain.
        public static let quick = Plan(tests: ["all", "gpu", "ssd"], duration: 30, baseline: 20,
                                       cooldownMinimum: 10, cooldownMaximum: 45)
    }

    /// Runs the baseline and the load tests of `plan` (the charger test is interactive
    /// and stays with the caller). Tests not in `loadTests` are skipped.
    public static func run(_ plan: Plan, recorder: SensorRecorder) {
        recorder.progress("baseline (\(Int(plan.baseline)) s)")
        recorder.phase("baseline", duration: plan.baseline)
        for test in plan.tests where loadTests.contains(test) {
            let reference = recorder.recentHotMean()
            let flag = StopFlag()
            switch test {
            case "single":
                LoadGenerator.cpu(threads: 1, flag: flag)
            case "all":
                LoadGenerator.cpu(threads: ProcessInfo.processInfo.activeProcessorCount, flag: flag)
            case "gpu":
                if let error = LoadGenerator.gpu(flag: flag) {
                    recorder.progress("gpu test skipped: \(error)")
                    continue
                }
            default:
                LoadGenerator.ssd(directory: FileManager.default.temporaryDirectory, fileSize: 2 << 30, flag: flag)
            }
            recorder.progress("\(test) load (\(Int(plan.duration)) s)")
            recorder.phase(test, duration: plan.duration)
            flag.stop()
            recorder.progress("cooldown")
            recorder.cooldown(to: reference, minimum: plan.cooldownMinimum, maximum: plan.cooldownMaximum)
        }
    }
}
