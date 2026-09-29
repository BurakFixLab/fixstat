import Foundation

/// Battery capacity (discharge) test: the Mac runs on battery under a steady load while
/// voltage, current and the gauge's values are sampled. The charge actually delivered is
/// compared with what the gauge claims:
///
/// - delivered ÷ drop in the displayed percentage → capacity extrapolated to 100 %;
///   far below the gauge's full charge capacity means the gauge overstates the pack
///   (typical for reset or non-genuine gauges showing a high health);
/// - delivered ÷ drop in the gauge's remaining capacity (RM) → gauge agreement, about 1
///   for a gauge that counts correctly;
/// - the voltage step when the load starts → DC pack resistance;
/// - cell voltages under load → a weak cell sags first.
///
/// Current and voltage come from the gauge itself, so this cannot replace an external
/// analyser; it finds gauges whose percentages and capacities do not add up.
public struct CapacitySample: Codable, Sendable, Equatable {
    /// Seconds since the test started.
    public var time: TimeInterval
    /// mV
    public var voltage: Int
    /// mA, negative while discharging.
    public var amperage: Int
    /// Displayed state of charge in %.
    public var percent: Double?
    /// Gauge remaining capacity (RM), mAh.
    public var remaining: Int?
    public var cells: [Int]?
    public var temperature: Double?
    /// true for the idle samples taken before the load starts.
    public var idle: Bool

    public init(time: TimeInterval, voltage: Int, amperage: Int, percent: Double?, remaining: Int?,
                cells: [Int]?, temperature: Double?, idle: Bool) {
        self.time = time
        self.voltage = voltage
        self.amperage = amperage
        self.percent = percent
        self.remaining = remaining
        self.cells = cells
        self.temperature = temperature
        self.idle = idle
    }
}

public struct CapacityResult: Codable, Sendable, Equatable {
    public enum StopReason: String, Codable, Sendable {
        case targetReached, stopped, adapterConnected, tooHot
        /// The Mac went to sleep or turned off by itself at the end of the charge.
        case batteryEmpty
        /// The Mac turned off while the gauge still showed charge (above 5 %).
        case unexpectedShutdown
    }

    public var stopReason: StopReason
    public var startedAt: Date
    public var duration: TimeInterval
    public var startPercent: Double?
    public var endPercent: Double?
    public var deliveredMAh: Double
    public var deliveredWh: Double
    public var averageWatts: Double?
    /// Drop of the gauge's remaining capacity (RM), mAh.
    public var gaugeDropMAh: Int?
    /// delivered ÷ gauge drop.
    public var gaugeAgreement: Double?
    /// delivered ÷ displayed percentage drop × 100.
    public var extrapolatedCapacity: Double?
    /// Gauge full charge capacity (AppleRawMaxCapacity) and design capacity at the start, mAh.
    public var fullChargeCapacity: Int?
    public var designCapacity: Int?
    /// DC pack resistance from the load step, mΩ (shown only: no reference values yet).
    public var packResistance: Double?
    /// Largest cell voltage spread under load, mV, and the cell that was lowest most often (1-based).
    public var maxCellSpread: Int?
    public var weakestCell: Int?
    public var lowestVoltage: Int?
    public var highestTemperature: Double?

    /// extrapolated ÷ gauge full charge capacity.
    public var capacityAgreement: Double? {
        guard let e = extrapolatedCapacity, let f = fullChargeCapacity, f > 0 else { return nil }
        return e / Double(f)
    }

    public enum Finding: Equatable, Sendable {
        case tooShort
        case capacityBelowGauge(Double)
        case gaugeMiscount(Double)
        case weakCell(Int, Int)
        /// Turned off at this displayed charge: the pack could not deliver what the gauge showed.
        case shutdownAtCharge(Double)
    }

    /// The percentage drop needed for a meaningful extrapolation (1 % steps).
    public static let minimumPercentDrop = 20.0

    public var findings: [Finding] {
        var result: [Finding] = []
        if stopReason == .unexpectedShutdown, let p = endPercent { result.append(.shutdownAtCharge(p)) }
        let drop = (startPercent ?? 0) - (endPercent ?? 0)
        if drop < Self.minimumPercentDrop { result.append(.tooShort) }
        if drop >= Self.minimumPercentDrop, let a = capacityAgreement, a < 0.85 { result.append(.capacityBelowGauge(a)) }
        if drop >= Self.minimumPercentDrop, let g = gaugeAgreement, abs(g - 1) > 0.1 { result.append(.gaugeMiscount(g)) }
        if let spread = maxCellSpread, spread > 80, let cell = weakestCell { result.append(.weakCell(cell, spread)) }
        return result
    }

    public static func compute(samples: [CapacitySample], startedAt: Date, stopReason: StopReason,
                               fullChargeCapacity: Int?, designCapacity: Int?) -> CapacityResult {
        let loaded = samples.filter { !$0.idle }
        var mAh = 0.0
        var wh = 0.0
        for (a, b) in zip(loaded, loaded.dropFirst()) {
            let dt = b.time - a.time
            guard dt > 0, dt < 120 else { continue } // skip gaps (e.g. the Mac slept)
            let current = (Double(-a.amperage) + Double(-b.amperage)) / 2 // mA, discharge positive
            guard current > 0 else { continue }
            let volts = (Double(a.voltage) + Double(b.voltage)) / 2000
            mAh += current * dt / 3600
            wh += current / 1000 * volts * dt / 3600
        }
        let first = loaded.first
        let last = loaded.last
        let duration = (last?.time ?? 0) - (first?.time ?? 0)
        var result = CapacityResult(
            stopReason: stopReason, startedAt: startedAt, duration: duration,
            startPercent: first?.percent, endPercent: last?.percent,
            deliveredMAh: mAh, deliveredWh: wh, averageWatts: duration > 0 ? wh / (duration / 3600) : nil,
            fullChargeCapacity: fullChargeCapacity, designCapacity: designCapacity)
        if let r0 = first?.remaining, let r1 = last?.remaining, r0 > r1 {
            result.gaugeDropMAh = r0 - r1
            result.gaugeAgreement = mAh / Double(r0 - r1)
        }
        if let p0 = first?.percent, let p1 = last?.percent, p0 - p1 >= 1 {
            result.extrapolatedCapacity = mAh / ((p0 - p1) / 100)
        }
        // Load step: last idle sample vs. the first loaded sample at least 60 s later
        // (the gauge's Amperage is averaged and needs time to settle).
        if let idle = samples.last(where: \.idle),
           let step = loaded.first(where: { $0.time - idle.time >= 60 }) {
            let dv = Double(idle.voltage - step.voltage)
            let di = Double(idle.amperage - step.amperage) // both negative; load draws more
            if di > 200, dv > 0 { result.packResistance = dv / di * 1000 }
        }
        var spread = 0
        var lowestCount: [Int: Int] = [:]
        for s in loaded {
            guard let cells = s.cells, cells.count > 1, let lo = cells.min(), let hi = cells.max() else { continue }
            spread = max(spread, hi - lo)
            if hi - lo >= 10, let index = cells.firstIndex(of: lo) { lowestCount[index + 1, default: 0] += 1 }
        }
        result.maxCellSpread = loaded.contains { ($0.cells?.count ?? 0) > 1 } ? spread : nil
        result.weakestCell = lowestCount.max { $0.value < $1.value }?.key
        result.lowestVoltage = loaded.map(\.voltage).min()
        result.highestTemperature = samples.compactMap(\.temperature).max()
        return result
    }
}
