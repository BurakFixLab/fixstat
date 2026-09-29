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
    }

    public var tool = "sensormap"
    public var version = MacSensors.version
    public var system: SystemInfo
    public var startedAt: Date
    public var sensors: [SensorDescriptor]
    public var phases: [Phase] = []
    public var samples: [Sample] = []
}

/// Drives the load tests and collects samples once per second.
public final class SensorRecorder {
    public let sampler = TemperatureSampler()
    public var recording: SensorRecording
    private let start = Date()
    public let interval: TimeInterval
    /// Progress lines (e.g. printed to stderr by the command-line tools).
    public var progress: (String) -> Void = { _ in }

    public init(interval: TimeInterval = 1) {
        self.interval = interval
        recording = SensorRecording(system: .current(), startedAt: Date(), sensors: sampler.sensors)
    }

    public var now: Double { Date().timeIntervalSince(start) }

    public func takeSample() {
        let battery = BatteryReader.read()
        recording.samples.append(.init(t: now, values: sampler.sample(),
                                       batteryAmperage: battery?.amperage,
                                       externalConnected: battery?.externalConnected))
    }

    /// Samples for `duration` seconds and records the span as a phase.
    public func phase(_ name: String, duration: TimeInterval, until stop: (() -> Bool)? = nil) {
        let phaseStart = now
        let deadline = Date().addingTimeInterval(duration)
        var lastLog = Date.distantPast
        while Date() < deadline {
            let tick = Date()
            takeSample()
            if stop?() == true { break }
            if Date().timeIntervalSince(lastLog) >= 10 {
                progress("  \(name): \(Int(now - phaseStart)) s, mean HID \(SensorMapReport.fmt(meanHID(recording.samples.last)))")
                lastLog = Date()
            }
            let elapsed = Date().timeIntervalSince(tick)
            if elapsed < interval { Thread.sleep(forTimeInterval: interval - elapsed) }
        }
        recording.phases.append(.init(name: name, start: phaseStart, end: now))
    }

    /// Cools down until the mean of the HID temperatures is within `tolerance`
    /// of `target`, bounded by `minimum` and `maximum` seconds.
    public func cooldown(to target: Double?, tolerance: Double = 1.0, minimum: TimeInterval, maximum: TimeInterval) {
        let begin = Date()
        phase("cooldown", duration: maximum) { [self] in
            guard Date().timeIntervalSince(begin) >= minimum else { return false }
            guard let target, let current = meanHID(recording.samples.last) else { return true }
            return current <= target + tolerance
        }
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
            let reference = recorder.recentMeanHID()
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
