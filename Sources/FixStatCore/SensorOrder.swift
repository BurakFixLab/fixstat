import Foundation
import MacSensors

/// Order of sensors in every list.
public enum SensorOrder {
    /// Id prefixes in display order; unlisted ids come after, by group.
    private static let idOrder = ["cpu.pcluster", "cpu.ecluster", "cpu.", "gpu.", "ssd.nand", "ssd.",
                                  "battery.", "chassis.", "soc.", "board.", "pmu.", "pmu2."]

    public static func displayOrder(_ a: DisplaySensor, _ b: DisplaySensor) -> Bool {
        func rank(_ sensor: DisplaySensor) -> Int {
            guard let id = sensor.resolved?.id else { return idOrder.count + 1 }
            return idOrder.firstIndex { id.hasPrefix($0) } ?? idOrder.count
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        let ka = a.resolved?.id ?? a.name
        let kb = b.resolved?.id ?? b.name
        return ka.localizedStandardCompare(kb) == .orderedAscending
    }
}

/// Aggregated rows of the default panel: the hottest sensor of each kind.
public enum SensorSummary: CaseIterable {
    case performanceClusters, efficiencyClusters, cpu, gpu, ssd, enclosure, battery

    public var title: String {
        switch self {
        case .performanceClusters: return L("Performance clusters")
        case .efficiencyClusters: return L("Efficiency clusters")
        case .cpu: return L("CPU")
        case .gpu: return L("GPU")
        case .ssd: return L("SSD (NAND)")
        case .enclosure: return L("Enclosure")
        case .battery: return L("Battery")
        }
    }

    public var prefixes: [String] {
        switch self {
        case .performanceClusters: return ["cpu.pcluster"]
        case .efficiencyClusters: return ["cpu.ecluster"]
        case .cpu: return ["cpu.core", "cpu.die", "cpu.proximity"]
        case .gpu: return ["gpu."]
        case .ssd: return ["ssd.nand", "ssd."]
        case .enclosure: return ["chassis.skin", "chassis.palmrest"]
        case .battery: return ["battery."]
        }
    }

    /// Up to six rows with a value, in display order.
    public static func rows(sensors: [DisplaySensor], values: [String: Double],
                            hidden: Set<String>) -> [(title: String, value: Double)] {
        let rows = allCases.compactMap { summary -> (title: String, value: Double)? in
            MonitorCore.maximum(sensors: sensors, values: values, idPrefixes: summary.prefixes, excluding: hidden)
                .map { (summary.title, $0) }
        }
        return Array(rows.prefix(6))
    }
}
