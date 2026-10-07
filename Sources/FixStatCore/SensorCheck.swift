import Foundation
import MacSensors

/// Result of the broken-sensor check: suspicious sensors and the symptoms a missing or
/// broken sensor typically causes.
public struct SensorCheckResult: Equatable {
    public var date: Date
    public var seconds: Double
    /// Named sensors that were judged.
    public var sensorCount: Int
    public var faults: [SensorFault]
    /// Display names by `SensorFault.uid`.
    public var names: [String: String]
    /// Median of the hottest CPU sensor over the check.
    public var hottestCPU: Double?
    /// Fans at ≥ 85 % of their maximum while the CPU was cool: (actual, maximum) rpm.
    public var fansNearMax: [FanSpeed]
    /// Intel: the CPU speed limit macOS applies (`pmset -g therm`), when below 100 %.
    public var cpuSpeedLimit: Int?
    /// Mean shares of all CPUs during the check (0…1).
    public var systemShare: Double?
    public var userShare: Double?

    public struct FanSpeed: Equatable {
        public var actual: Double
        public var maximum: Double
    }

    /// Faults of sensors this Mac certainly has (named by its model or chip entry).
    public var known: [SensorFault] { faults.filter(\.known) }
    /// Faults of sensors only guessed from the key pattern: maybe not fitted on this model.
    public var unclear: [SensorFault] { faults.filter { !$0.known } }

    /// The CPU is held back although it is not hot.
    public var throttled: Bool {
        guard let limit = cpuSpeedLimit, limit < 100 else { return false }
        return (hottestCPU ?? 0) < SensorCheck.throttleBelow
    }

    /// The kernel takes much CPU time while little else runs (kernel_task keeping the CPU idle).
    public var kernelBusy: Bool {
        guard let system = systemShare, let user = userShare else { return false }
        return system >= SensorCheck.kernelShare && user < SensorCheck.quietUserShare
    }

    public var hasSymptoms: Bool { !fansNearMax.isEmpty || throttled || kernelBusy }
    public var passed: Bool { known.isEmpty && !hasSymptoms }
}

public enum SensorCheck {
    public static let duration: TimeInterval = 60
    /// Fans this close to their maximum…
    public static let fanNearMax = 0.85
    /// …while the CPU is below this many °C point to the firmware reacting to a sensor.
    public static let fanCoolCPU = 65.0
    public static let throttleBelow = 80.0
    public static let kernelShare = 0.25
    public static let quietUserShare = 0.15

    /// Builds the result from the samples (per sensor, values over time; per sample, the fans).
    static func result(sensors: [DisplaySensor], series: [[Double?]], fans: [[FanReading]], seconds: Double,
                       thermal: ThermalStatus?, load: (system: Double, user: Double)?) -> SensorCheckResult {
        var judged: [SensorFaultDetector.Sensor] = []
        var judgedSeries: [[Double?]] = []
        var names: [String: String] = [:]
        for (sensor, values) in zip(sensors, series) {
            guard let resolved = sensor.resolved else { continue }
            judged.append(SensorFaultDetector.Sensor(descriptor: sensor.descriptor, resolved: resolved))
            judgedSeries.append(values)
            names[sensor.id] = sensor.name
        }
        let faults = SensorFaultDetector.detect(judged, series: judgedSeries, seconds: seconds)

        // Hottest active CPU zone per sample, then the median over the check.
        let cpuColumns = sensors.indices.filter { sensors[$0].group == .cpu }
        let samples = series.first?.count ?? 0
        let hottest = (0..<samples).compactMap { index -> Double? in
            cpuColumns.compactMap { series[$0][index] }
                .filter { SMC.plausibleTemperatureRange.contains($0) && $0 >= SMC.minimumActiveDieTemperature }.max()
        }.sorted()
        let hottestCPU = hottest.isEmpty ? nil : hottest[hottest.count / 2]

        // Fans: mean over the last ten samples.
        var fansNearMax: [SensorCheckResult.FanSpeed] = []
        let recent = fans.suffix(10)
        if let count = recent.last?.count, (hottestCPU ?? 0) < fanCoolCPU {
            for index in 0..<count {
                let actual = recent.compactMap { index < $0.count ? $0[index].actual : nil }
                guard !actual.isEmpty, let maximum = recent.last?[index].maximum, maximum > 0 else { continue }
                let mean = actual.reduce(0, +) / Double(actual.count)
                if mean >= fanNearMax * maximum { fansNearMax.append(.init(actual: mean, maximum: maximum)) }
            }
        }

        return SensorCheckResult(date: Date(), seconds: seconds, sensorCount: judged.count, faults: faults, names: names,
                                 hottestCPU: hottestCPU, fansNearMax: fansNearMax,
                                 cpuSpeedLimit: thermal?.cpuSpeedLimit.flatMap { $0 < 100 ? $0 : nil },
                                 systemShare: load?.system, userShare: load?.user)
    }
}

/// Watches every sensor once per second for `SensorCheck.duration` without putting load on the
/// Mac; the result goes to `MonitorCore.lastSensorCheck` and the hardware check.
public final class SensorCheckRunner {
    public enum State: Equatable { case idle, running, finished }

    public private(set) var state = State.idle
    public private(set) var elapsed: TimeInterval = 0
    /// Seconds to watch (shorter for snapshots: `-FixStatSensorCheckSeconds N`).
    public var duration: TimeInterval = {
        let seconds = UserDefaults.standard.double(forKey: "FixStatSensorCheckSeconds")
        return seconds > 0 ? seconds : SensorCheck.duration
    }()
    public var onChange: (() -> Void)?

    private let monitor: MonitorCore
    private var timer: Timer?
    private var startedAt = Date()
    private var sensors: [DisplaySensor] = []
    private var series: [[Double?]] = []
    private var fans: [[FanReading]] = []
    private var stats = SystemStats()
    private var loads: [(user: Double, system: Double)] = []

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public var fraction: Double { min(elapsed / duration, 1) }

    public func start() {
        guard state != .running else { return }
        state = .running
        startedAt = Date()
        elapsed = 0
        sensors = []
        series = []
        fans = []
        loads = []
        stats = SystemStats()
        _ = stats.cpuLoad()
        monitor.testRunning = true
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onChange?()
    }

    public func stop() {
        guard state == .running else { return }
        timer?.invalidate()
        timer = nil
        monitor.testRunning = false
        state = .idle
        onChange?()
    }

    private func tick() {
        monitor.refresh()
        // The sensors are known once the SMC was enumerated (in the background at launch).
        if sensors.isEmpty {
            sensors = monitor.sensors
            series = Array(repeating: [], count: sensors.count)
        }
        guard !sensors.isEmpty else { return }
        let values = monitor.values
        for index in sensors.indices {
            series[index].append(values[sensors[index].id])
        }
        // `-FixStatSampleSensorFault YES`: the first SSD (or board) sensor reads as an open circuit.
        if UserDefaults.standard.bool(forKey: "FixStatSampleSensorFault"),
           let index = sensors.firstIndex(where: { $0.group == .ssd && $0.resolved != nil })
            ?? sensors.firstIndex(where: { $0.group == .other && $0.resolved != nil }) {
            series[index][series[index].count - 1] = -54.0
        }
        fans.append(monitor.fans)
        if let load = stats.cpuLoad() { loads.append(load) }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= duration {
            finish()
        } else {
            onChange?()
        }
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        monitor.testRunning = false
        let sensors = self.sensors, series = self.series, fans = self.fans, seconds = elapsed
        let load = loads.isEmpty ? nil : (system: loads.map(\.system).reduce(0, +) / Double(loads.count),
                                          user: loads.map(\.user).reduce(0, +) / Double(loads.count))
        let isAppleSilicon = monitor.system.isAppleSilicon
        // `pmset -g therm` (Intel speed limit) runs a process: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let thermal = isAppleSilicon ? nil : ThermalStatus.read()
            let result = SensorCheck.result(sensors: sensors, series: series, fans: fans, seconds: seconds,
                                            thermal: thermal, load: load)
            DispatchQueue.main.async {
                guard let self else { return }
                self.monitor.lastSensorCheck = result
                self.monitor.recordCheck(.sensors, detail: SensorCheckText.detail(result), passed: result.passed,
                                         failed: !result.known.isEmpty)
                self.state = .finished
                self.onChange?()
            }
        }
    }
}

public enum SensorCheckText {
    /// One line: what is wrong with the sensor.
    public static func fault(_ f: SensorFault, name: String?) -> String {
        let sensor = (name ?? f.label) + (name != nil && name != f.label ? " (\(f.label))" : "")
        let value = f.value.map { Format.degrees($0, digits: 1) } ?? "–"
        switch f.kind {
        case .open:
            return L("%1$@ reads %2$@: open circuit — the sensor or its connection (flex cable, connector).", sensor, value)
        case .short:
            return L("%1$@ reads %2$@: short circuit — the sensor or its line.", sensor, value)
        case .noReading:
            return L("%@ gives no reading: the sensor or its connection is missing.", sensor)
        case .frozen:
            return L("%1$@ stays at exactly %2$@ while the sensors around it change: stuck reading.", sensor, value)
        case .tooCold:
            return L("%1$@ reads %2$@, far colder than the rest of the Mac: sensor or connection.", sensor, value)
        }
    }

    public static func symptoms(_ r: SensorCheckResult) -> [String] {
        var lines: [String] = []
        let cpu = r.hottestCPU.map { Format.degrees($0) } ?? "–"
        for fan in r.fansNearMax {
            lines.append(L("A fan runs at %1$@ of %2$@ rpm although the CPU is only at %3$@. Macs speed their fans up like this when a temperature sensor is missing or broken.",
                           Format.number(fan.actual), Format.number(fan.maximum), cpu))
        }
        if r.throttled, let limit = r.cpuSpeedLimit {
            lines.append(L("macOS holds the CPU at %1$@ of its speed although it is not hot (%2$@). A missing or broken sensor is a common cause, as are battery and power adapter problems.",
                           Format.percent(Double(limit)), cpu))
        }
        if r.kernelBusy, let system = r.systemShare {
            lines.append(L("The system (kernel_task) takes %@ of the CPU while little else runs: macOS keeps the CPU idle, often because of a missing sensor or a battery or power problem.",
                           Format.percent(system * 100)))
        }
        return lines
    }

    public static func verdict(_ r: SensorCheckResult) -> String {
        if !r.known.isEmpty { return L("Suspicious sensors: %lld.", r.known.count) }
        if r.hasSymptoms { return L("No broken sensor found, but the Mac behaves as if one were missing.") }
        return L("All %lld sensors read plausible values.", r.sensorCount)
    }

    /// Evidence for the hardware check and the report.
    public static func detail(_ r: SensorCheckResult) -> String {
        var parts = [verdict(r)]
        parts += r.known.map { fault($0, name: r.names[$0.uid]) }
        if !r.unclear.isEmpty {
            parts.append(L("Unclear: %@", r.unclear.map(\.label).joined(separator: ", ")))
        }
        parts += symptoms(r)
        return parts.joined(separator: " ")
    }

    public static let unclearNote = L("Only guessed from the key name, so they may simply not be fitted on this model. Compare with a good Mac of the same model.")
}
