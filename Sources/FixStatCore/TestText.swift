import Foundation
import MacSensors

/// Localized texts for test results (shared by the window and the PDF report).
public enum TestText {
    public static func finding(_ finding: StressTestResult.Finding) -> String {
        switch finding {
        case let .highChipTemperature(group, celsius, limit):
            let name = group == "gpu" ? "GPU" : "CPU"
            return L("%@ reached %@ (limit %@)", name, Format.temperature(celsius), Format.temperature(limit, digits: 0))
        case let .highBatteryTemperature(celsius, limit):
            return L("Battery reached %@ (limit %@)", Format.temperature(celsius), Format.temperature(limit, digits: 0))
        case let .cellVoltageSag(cell, millivolts, limit):
            return L("Cell %lld dropped to %@ under load (limit %@)", cell, Format.volts(millivolts: millivolts, digits: 3), Format.volts(millivolts: limit, digits: 1))
        case let .cellImbalance(millivolts, limit):
            return L("Cell spread reached %@ under load (limit %@)", Format.millivolts(millivolts), Format.millivolts(limit))
        case let .adapterDeficit(average):
            return L("On the power adapter the battery was still discharging (average %@) — adapter, cable or charging circuit may be weak", Format.milliamps(average))
        case .stoppedEarly:
            return L("Test was stopped before the planned duration")
        }
    }

    public static func summaryRows(_ r: StressTestResult) -> [(String, String)] {
        var rows: [(String, String)] = [
            (L("Duration"), Format.minutesSeconds(r.duration)),
            (L("Highest CPU temperature"), r.maxCPU.map { Format.temperature($0) } ?? "–"),
            (L("Highest GPU temperature"), r.maxGPU.map { Format.temperature($0) } ?? "–"),
            (L("Highest SSD temperature"), r.maxSSD.map { Format.temperature($0) } ?? "–"),
            (L("Highest battery temperature"), r.maxBattery.map { Format.temperature($0) } ?? "–"),
            (L("Time at or above hot threshold"), Format.minutesSeconds(r.secondsAboveHot)),
        ]
        if let v = r.minCellVoltage {
            rows.append((L("Lowest cell voltage"), Format.volts(millivolts: v, digits: 3)))
        }
        if let s = r.maxCellSpread {
            rows.append((L("Largest cell spread"), Format.millivolts(s)))
        }
        if let a = r.socStart, let b = r.socEnd {
            rows.append((L("Battery charge"), "\(Format.percent(a)) → \(Format.percent(b))"))
        }
        if let c = r.averageCurrent {
            rows.append((L("Average battery current"), Format.milliamps(c)))
        }
        return rows
    }
}
