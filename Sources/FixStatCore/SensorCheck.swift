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
    /// Whether CPU and GPU were loaded to see which sensors follow.
    public var underLoad: Bool
    /// Median of the hottest CPU sensor while idle.
    public var hottestCPU: Double?
    /// Fans at ≥ 85 % of their maximum while idle with a cool CPU.
    public var fansNearMax: [FanSpeed]
    /// Intel: the CPU speed limit macOS applies (`pmset -g therm`), when below 100 %.
    public var cpuSpeedLimit: Int?
    /// Mean shares of all CPUs while idle (0…1).
    public var systemShare: Double?
    public var userShare: Double?

    public struct FanSpeed: Equatable {
        public var actual: Double
        public var maximum: Double
    }

    /// Faults of sensors this Mac certainly has.
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
    /// Idle only: one minute (a stuck sensor needs that long to show).
    public static let idleDuration: TimeInterval = 60
    /// With load: a short idle part (symptoms, the start values), then CPU and GPU load.
    public static let idleBeforeLoad: TimeInterval = 20
    public static let loadDuration: TimeInterval = 45
    /// Fans this close to their maximum…
    public static let fanNearMax = 0.85
    /// …while the CPU is below this many °C point to the firmware reacting to a sensor.
    public static let fanCoolCPU = 65.0
    public static let throttleBelow = 80.0
    public static let kernelShare = 0.25
    public static let quietUserShare = 0.15

    /// - Parameters:
    ///   - series: per sensor, its values over the whole check (idle first, then under load).
    ///   - idleSamples: how many samples at the start were taken idle.
    ///   - fans: per idle sample, the fans.
    static func result(sensors: [DisplaySensor], series: [[Double?]], idleSamples: Int, fans: [[FanReading]],
                       seconds: Double, missing: [SensorFault], missingNames: [String: String],
                       thermal: ThermalStatus?, load: (system: Double, user: Double)?) -> SensorCheckResult {
        var judged: [SensorFaultDetector.Sensor] = []
        var judgedSeries: [[Double?]] = []
        var names = missingNames
        for (sensor, values) in zip(sensors, series) {
            guard let resolved = sensor.resolved else { continue }
            judged.append(SensorFaultDetector.Sensor(descriptor: sensor.descriptor, resolved: resolved))
            judgedSeries.append(values)
            names[sensor.id] = sensor.name
        }
        var faults = missing + SensorFaultDetector.detect(judged, series: judgedSeries, seconds: seconds)
        let samples = series.first?.count ?? 0
        let underLoad = samples > idleSamples
        if underLoad {
            let before = judgedSeries.map { Array($0.prefix(idleSamples).suffix(10)) }
            let during = judgedSeries.map { Array($0.dropFirst(idleSamples)) }
            let flagged = Set(faults.map(\.uid))
            faults += SensorFaultDetector.unresponsive(judged, before: before, during: during)
                .filter { !flagged.contains($0.uid) }
        }

        // Hottest active CPU zone per idle sample, then the median.
        let cpuColumns = sensors.indices.filter { sensors[$0].group == .cpu }
        let hottest = (0..<min(idleSamples, samples)).compactMap { index -> Double? in
            cpuColumns.compactMap { series[$0][index] }
                .filter { SMC.plausibleTemperatureRange.contains($0) && $0 >= SMC.minimumActiveDieTemperature }.max()
        }.sorted()
        let hottestCPU = hottest.isEmpty ? nil : hottest[hottest.count / 2]

        // Fans: mean over the last ten idle samples.
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
                                 underLoad: underLoad, hottestCPU: hottestCPU, fansNearMax: fansNearMax,
                                 cpuSpeedLimit: thermal?.cpuSpeedLimit.flatMap { $0 < 100 ? $0 : nil },
                                 systemShare: load?.system, userShare: load?.user)
    }
}

/// Watches every sensor once per second with the Mac idle and, optionally, under CPU and GPU
/// load; the result goes to `MonitorCore.lastSensorCheck` and the hardware check.
public final class SensorCheckRunner {
    public enum State: Equatable { case idle, running, finished }
    public enum Phase: Equatable { case idle, load }

    public private(set) var state = State.idle
    public private(set) var phase = Phase.idle
    public private(set) var elapsed: TimeInterval = 0
    /// Put CPU and GPU under load after a short idle part.
    public var underLoad = true
    public var onChange: (() -> Void)?

    /// Shortens the check (snapshots): this many seconds idle and as many under load. Also set
    /// by `-FixStatSensorCheckSeconds N`.
    public var shortened: TimeInterval? = {
        let seconds = UserDefaults.standard.double(forKey: "FixStatSensorCheckSeconds")
        return seconds > 0 ? seconds : nil
    }()
    private var idleSeconds: TimeInterval {
        shortened ?? (underLoad ? SensorCheck.idleBeforeLoad : SensorCheck.idleDuration)
    }
    private var loadSeconds: TimeInterval { underLoad ? shortened ?? SensorCheck.loadDuration : 0 }
    public var duration: TimeInterval { idleSeconds + loadSeconds }

    private let monitor: MonitorCore
    private var timer: Timer?
    private var startedAt = Date()
    private var sensors: [DisplaySensor] = []
    private var series: [[Double?]] = []
    private var idleSamples = 0
    private var fans: [[FanReading]] = []
    private var stats = SystemStats()
    private var loads: [(user: Double, system: Double)] = []
    private var flag: StopFlag?
    private var activity: NSObjectProtocol?

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public var fraction: Double { min(elapsed / duration, 1) }
    public var remaining: TimeInterval { max(duration - elapsed, 0) }

    public func start() {
        guard state != .running else { return }
        state = .running
        phase = .idle
        startedAt = Date()
        elapsed = 0
        sensors = []
        series = []
        idleSamples = 0
        fans = []
        loads = []
        stats = SystemStats()
        _ = stats.cpuLoad()
        monitor.testRunning = true
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Sensor check")
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onChange?()
    }

    public func stop() {
        guard state == .running else { return }
        end()
        state = .idle
        onChange?()
    }

    private func end() {
        timer?.invalidate()
        timer = nil
        flag?.stop()
        flag = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        monitor.testRunning = false
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
        // `-FixStatSampleSensorFault YES`: the first SSD (or board) sensor reads as an open circuit,
        // and the first CPU sensor stays at its last idle value under load.
        if UserDefaults.standard.bool(forKey: "FixStatSampleSensorFault") {
            if let index = sensors.firstIndex(where: { $0.group == .ssd && $0.resolved != nil })
                ?? sensors.firstIndex(where: { $0.group == .other && $0.resolved != nil }) {
                series[index][series[index].count - 1] = -54.0
            }
            if phase == .load, idleSamples > 0, let index = sensors.firstIndex(where: { $0.group == .cpu }) {
                series[index][series[index].count - 1] = series[index][idleSamples - 1]
            }
        }
        elapsed = Date().timeIntervalSince(startedAt)
        if phase == .idle {
            idleSamples += 1
            fans.append(monitor.fans)
            if let load = stats.cpuLoad() { loads.append(load) }
            if elapsed >= idleSeconds, loadSeconds > 0 { startLoad() }
        }
        if elapsed >= duration {
            finish()
        } else {
            onChange?()
        }
    }

    private func startLoad() {
        phase = .load
        let flag = StopFlag()
        self.flag = flag
        // Leave one core for feeding the GPU, sampling and the UI.
        LoadGenerator.cpu(threads: max(1, ProcessInfo.processInfo.activeProcessorCount - 1), flag: flag)
        _ = LoadGenerator.gpu(flag: flag)
    }

    private func finish() {
        end()
        let sensors = self.sensors, series = self.series, fans = self.fans, seconds = elapsed
        let idleSamples = self.idleSamples
        let load = loads.isEmpty ? nil : (system: loads.map(\.system).reduce(0, +) / Double(loads.count),
                                          user: loads.map(\.user).reduce(0, +) / Double(loads.count))
        let missing = SensorFaultDetector.missing(map: monitor.map, model: monitor.system.model,
                                                  present: sensors.map(\.descriptor),
                                                  hasBattery: monitor.profile.hasBattery)
        var missingNames: [String: String] = [:]
        for fault in missing { missingNames[fault.uid] = fault.id.flatMap(SensorNames.localizedName(id:)) }
        let isAppleSilicon = monitor.system.isAppleSilicon
        // `pmset -g therm` (Intel speed limit) runs a process: off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let thermal = isAppleSilicon ? nil : ThermalStatus.read()
            let result = SensorCheck.result(sensors: sensors, series: series, idleSamples: idleSamples, fans: fans,
                                            seconds: seconds, missing: missing, missingNames: missingNames,
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
        case .missing:
            return L("%@ is missing: this model has it, but the Mac does not report it (flex cable, connector or the part).", sensor)
        case .noResponse:
            return L("%1$@ hardly moved under load (%2$@) while the other sensors of its group heated up: stuck or badly placed sensor.",
                     sensor, f.value.map { Format.degreesChange($0) } ?? "–")
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
        return r.underLoad ? L("All %lld sensors read plausible values and followed the load.", r.sensorCount)
            : L("All %lld sensors read plausible values.", r.sensorCount)
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
