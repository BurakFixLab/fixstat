import Foundation

/// Compares the cells of a pack to find a weak one.
///
/// A cell is flagged when its weighted resistance is more than
/// `resistanceThreshold` above the pack mean, or its Qmax is more than
/// `capacityThreshold` below the mean. Only relative differences are used, so
/// the undocumented resistance unit does not matter.
public struct CellAnalysis: Sendable, Equatable {
    public struct Cell: Sendable, Equatable {
        /// 1-based.
        public let number: Int
        public let voltage: Int?
        public let qmax: Int?
        public let resistance: Int?
        /// Relative deviation from the pack mean (0.12 = 12 % above).
        public let resistanceDeviation: Double?
        public let qmaxDeviation: Double?
        public let highResistance: Bool
        public let lowCapacity: Bool

        public var isSuspect: Bool { highResistance || lowCapacity }
    }

    public static let resistanceThreshold = 0.10
    public static let capacityThreshold = 0.03

    public let cells: [Cell]

    public init(battery: BatteryInfo) {
        let voltages = battery.cellVoltages ?? []
        let qmax = battery.cellQmax ?? []
        let resistance = battery.cellResistance ?? []
        let count = max(voltages.count, qmax.count, resistance.count)

        func mean(_ values: [Int]) -> Double? {
            let positive = values.filter { $0 > 0 }
            return positive.count == values.count && !values.isEmpty
                ? Double(positive.reduce(0, +)) / Double(positive.count) : nil
        }
        let meanResistance = mean(resistance)
        let meanQmax = mean(qmax)

        cells = (0..<count).map { index in
            let r = index < resistance.count ? resistance[index] : nil
            let q = index < qmax.count ? qmax[index] : nil
            let rDev = r.flatMap { value in meanResistance.map { (Double(value) - $0) / $0 } }
            let qDev = q.flatMap { value in meanQmax.map { (Double(value) - $0) / $0 } }
            return Cell(number: index + 1,
                        voltage: index < voltages.count ? voltages[index] : nil,
                        qmax: q, resistance: r,
                        resistanceDeviation: rDev, qmaxDeviation: qDev,
                        highResistance: (rDev ?? 0) > Self.resistanceThreshold,
                        lowCapacity: (qDev ?? 0) < -Self.capacityThreshold)
        }
    }

    public var suspects: [Cell] { cells.filter(\.isSuspect) }
}
