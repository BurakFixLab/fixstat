import Foundation

/// One sample taken during a post-repair stress test.
public struct StressSample: Codable, Sendable, Equatable {
    /// Seconds since the start of the test.
    public var time: Double
    /// Hottest sensor of each group, °C.
    public var cpu: Double?
    public var gpu: Double?
    public var ssd: Double?
    public var battery: Double?
    /// mV per cell.
    public var cellVoltages: [Int]?
    /// mA, positive = charging.
    public var amperage: Int?
    public var stateOfCharge: Double?
    public var externalConnected: Bool?

    public init(time: Double, cpu: Double?, gpu: Double?, ssd: Double?, battery: Double?,
                cellVoltages: [Int]?, amperage: Int?, stateOfCharge: Double?, externalConnected: Bool?) {
        self.time = time
        self.cpu = cpu
        self.gpu = gpu
        self.ssd = ssd
        self.battery = battery
        self.cellVoltages = cellVoltages
        self.amperage = amperage
        self.stateOfCharge = stateOfCharge
        self.externalConnected = externalConnected
    }
}

/// Summary and findings of a stress test.
public struct StressTestResult: Codable, Sendable, Equatable {
    public enum Finding: Codable, Sendable, Equatable {
        /// CPU or GPU reached `limit` °C or more.
        case highChipTemperature(group: String, celsius: Double, limit: Double)
        case highBatteryTemperature(celsius: Double, limit: Double)
        /// A cell dropped below `limit` mV under load.
        case cellVoltageSag(cell: Int, millivolts: Int, limit: Int)
        /// Cell spread exceeded `limit` mV under load.
        case cellImbalance(millivolts: Int, limit: Int)
        /// On AC power the battery was still discharging (adapter cannot carry the load).
        case adapterDeficit(averageMilliamps: Int)
        /// The test was stopped before the planned duration.
        case stoppedEarly
    }

    /// Apple Silicon throttles around 100 °C by design (fanless MacBook Air reaches it
    /// under full load), so the warning starts above that range.
    public static let chipTemperatureLimit = 105.0
    public static let batteryTemperatureLimit = 45.0
    public static let cellVoltageLimit = 3300
    public static let adapterDeficitLimit = -100

    public var startedAt: Date
    public var plannedDuration: TimeInterval
    public var duration: TimeInterval
    public var loads: [String]
    public var maxCPU: Double?
    public var maxGPU: Double?
    public var maxSSD: Double?
    public var maxBattery: Double?
    public var minCellVoltage: Int?
    public var maxCellSpread: Int?
    public var socStart: Double?
    public var socEnd: Double?
    public var averageCurrent: Int?
    /// Seconds with CPU or GPU at or above the user's "hot" threshold.
    public var secondsAboveHot: Double
    public var findings: [Finding]

    public var passed: Bool { findings.allSatisfy { $0 == .stoppedEarly } }

    public static func analyze(samples: [StressSample], startedAt: Date, plannedDuration: TimeInterval,
                               loads: [String], hotThreshold: Double, imbalanceThreshold: Int) -> StressTestResult {
        func maximum(_ values: [Double?]) -> Double? { values.compactMap { $0 }.max() }
        let cells = samples.compactMap(\.cellVoltages).filter { !$0.isEmpty }
        let minCell = cells.flatMap { $0 }.min()
        let maxSpread = cells.map { ($0.max() ?? 0) - ($0.min() ?? 0) }.max()
        let currents = samples.compactMap(\.amperage)
        let averageCurrent = currents.isEmpty ? nil : currents.reduce(0, +) / currents.count

        // Time above the hot threshold, weighting each sample by the gap to the next.
        var aboveHot = 0.0
        for (index, sample) in samples.enumerated() where index + 1 < samples.count {
            let hottest = max(sample.cpu ?? -.infinity, sample.gpu ?? -.infinity)
            if hottest >= hotThreshold { aboveHot += samples[index + 1].time - sample.time }
        }

        var findings: [Finding] = []
        let maxCPU = maximum(samples.map(\.cpu))
        let maxGPU = maximum(samples.map(\.gpu))
        let maxBattery = maximum(samples.map(\.battery))
        if let t = maxCPU, t >= chipTemperatureLimit {
            findings.append(.highChipTemperature(group: "cpu", celsius: t, limit: chipTemperatureLimit))
        }
        if let t = maxGPU, t >= chipTemperatureLimit {
            findings.append(.highChipTemperature(group: "gpu", celsius: t, limit: chipTemperatureLimit))
        }
        if let t = maxBattery, t >= batteryTemperatureLimit {
            findings.append(.highBatteryTemperature(celsius: t, limit: batteryTemperatureLimit))
        }
        if let lowest = minCell, lowest < cellVoltageLimit,
           let cell = cells.compactMap({ $0.firstIndex(of: lowest) }).first {
            findings.append(.cellVoltageSag(cell: cell + 1, millivolts: lowest, limit: cellVoltageLimit))
        }
        if let spread = maxSpread, spread > imbalanceThreshold * 2 {
            findings.append(.cellImbalance(millivolts: spread, limit: imbalanceThreshold * 2))
        }
        let onAC = samples.filter { $0.externalConnected == true }.compactMap(\.amperage)
        if onAC.count >= max(5, samples.count / 2) {
            let average = onAC.reduce(0, +) / onAC.count
            if average < adapterDeficitLimit { findings.append(.adapterDeficit(averageMilliamps: average)) }
        }
        let duration = samples.last?.time ?? 0
        if duration + 5 < plannedDuration { findings.append(.stoppedEarly) }

        return StressTestResult(
            startedAt: startedAt, plannedDuration: plannedDuration, duration: duration, loads: loads,
            maxCPU: maxCPU, maxGPU: maxGPU, maxSSD: maximum(samples.map(\.ssd)), maxBattery: maxBattery,
            minCellVoltage: minCell, maxCellSpread: maxSpread,
            socStart: samples.first?.stateOfCharge, socEnd: samples.last?.stateOfCharge,
            averageCurrent: averageCurrent, secondsAboveHot: aboveHot, findings: findings
        )
    }
}
