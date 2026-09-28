import Foundation
import MacSensors

/// A recorded sensor session: samples plus the phases they belong to.
struct Recording: Codable {
    struct Phase: Codable {
        /// "baseline", "single", "all", "gpu", "ssd", "unplugged", "charging", "cooldown"
        var name: String
        var start: Double
        var end: Double
    }

    struct Sample: Codable {
        /// Seconds since the start of the recording.
        var t: Double
        var values: [Double?]
        var batteryAmperage: Int?
        var externalConnected: Bool?
    }

    var tool = "sensormap"
    var version = MacSensors.version
    var system: SystemInfo
    var startedAt: Date
    var sensors: [SensorDescriptor]
    var phases: [Phase] = []
    var samples: [Sample] = []
}

/// Drives the load tests and collects samples once per second.
final class Recorder {
    let sampler = TemperatureSampler()
    var recording: Recording
    private let start = Date()
    let interval: TimeInterval

    init(interval: TimeInterval = 1) {
        self.interval = interval
        recording = Recording(system: .current(), startedAt: Date(), sensors: sampler.sensors)
    }

    var now: Double { Date().timeIntervalSince(start) }

    func takeSample() {
        let battery = BatteryReader.read()
        recording.samples.append(.init(t: now, values: sampler.sample(),
                                       batteryAmperage: battery?.amperage,
                                       externalConnected: battery?.externalConnected))
    }

    /// Samples for `duration` seconds and records the span as a phase.
    func phase(_ name: String, duration: TimeInterval, until stop: (() -> Bool)? = nil) {
        let phaseStart = now
        let deadline = Date().addingTimeInterval(duration)
        var lastLog = Date.distantPast
        while Date() < deadline {
            let tick = Date()
            takeSample()
            if stop?() == true { break }
            if Date().timeIntervalSince(lastLog) >= 10 {
                log("  \(name): \(Int(now - phaseStart)) s, mean HID \(fmt(meanHID(recording.samples.last)))")
                lastLog = Date()
            }
            let elapsed = Date().timeIntervalSince(tick)
            if elapsed < interval { Thread.sleep(forTimeInterval: interval - elapsed) }
        }
        recording.phases.append(.init(name: name, start: phaseStart, end: now))
    }

    /// Cools down until the mean of the HID temperatures is within `tolerance`
    /// of `target`, bounded by `minimum` and `maximum` seconds.
    func cooldown(to target: Double?, tolerance: Double = 1.0, minimum: TimeInterval, maximum: TimeInterval) {
        let begin = Date()
        phase("cooldown", duration: maximum) { [self] in
            guard Date().timeIntervalSince(begin) >= minimum else { return false }
            guard let target, let current = meanHID(recording.samples.last) else { return true }
            return current <= target + tolerance
        }
    }

    /// Mean over plausible HID sensor values of one sample.
    func meanHID(_ sample: Recording.Sample?) -> Double? {
        guard let sample else { return nil }
        let values = zip(recording.sensors, sample.values).compactMap { sensor, value -> Double? in
            guard sensor.source == .hid, let value, SMC.plausibleTemperatureRange.contains(value) else { return nil }
            return value
        }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Mean HID temperature over the last `seconds` of samples.
    func recentMeanHID(seconds: Double = 10) -> Double? {
        let cutoff = now - seconds
        let values = recording.samples.filter { $0.t >= cutoff }.compactMap(meanHID)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fmt(_ value: Double?, _ digits: Int = 1) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(digits)f", value)
}
