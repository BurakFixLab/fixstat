import Foundation
import MacSensors

/// Texts of the battery details window (both interfaces).
public enum BatteryDetailText {
    /// Undocumented bit fields as reported ("0" = none).
    public static func hex(_ value: Int?) -> String? {
        value.map { $0 == 0 ? "0" : String(format: "0x%X", $0) }
    }

    public static func manufacturer(_ battery: BatteryInfo) -> String? {
        guard let strings = battery.identity?.manufacturerStrings, !strings.isEmpty else { return nil }
        return strings.joined(separator: " · ")
    }

    /// "359 of 1,000"
    public static func cycles(_ battery: BatteryInfo) -> String? {
        guard let count = battery.cycleCount else { return nil }
        guard let design = battery.designCycleCount else { return Format.number(Double(count)) }
        return L("%@ of %@", Format.number(Double(count)), Format.number(Double(design)))
    }

    /// Operating time as reported by the gauge, in hours.
    public static func hours(_ value: Int) -> String {
        L("%@ h", Format.number(Double(value)))
    }

    // MARK: Cells

    public static func deviation(_ cell: CellAnalysis.Cell) -> String {
        [cell.resistanceDeviation.map { "R " + Format.signedPercent($0) },
         cell.qmaxDeviation.map { "Q " + Format.signedPercent($0) }]
            .compactMap { $0 }
            .joined(separator: "  ")
    }

    public static func finding(_ cell: CellAnalysis.Cell) -> String {
        var parts: [String] = []
        if cell.lowVoltage, let voltage = cell.voltage {
            parts.append(L("%1$@, below %2$@: over-discharged", Format.volts(millivolts: voltage, digits: 3),
                           Format.volts(millivolts: CellAnalysis.minimumVoltage, digits: 1)))
        }
        if cell.highResistance, let dev = cell.resistanceDeviation {
            parts.append(L("resistance %@ vs. average", Format.signedPercent(dev)))
        }
        if cell.lowCapacity, let dev = cell.qmaxDeviation {
            parts.append(L("Qmax %@ vs. average", Format.signedPercent(dev)))
        }
        return L("Cell %lld: %@", cell.number, parts.joined(separator: ", "))
    }

    /// Shown instead of "Cells are consistent." when the Qmax values are the gauge's defaults.
    public static var defaultQmax: String {
        L("Every Qmax equals the design capacity: the gauge has not learned the cells yet (new pack, or a gauge that lost power), so they cannot be compared.")
    }

    // MARK: Charger

    public static func input(_ telemetry: PowerTelemetry?) -> String? {
        guard let power = telemetry?.systemPowerIn, power > 0 else { return nil }
        var parts = [Format.watts(Double(power) / 1000, digits: 1)]
        if let v = telemetry?.systemVoltageIn { parts.append(Format.volts(millivolts: v)) }
        if let i = telemetry?.systemCurrentIn { parts.append(Format.milliamps(i, signed: false)) }
        return parts.joined(separator: " · ")
    }

    public static func notCharging(_ value: Int?) -> String? {
        guard let value else { return nil }
        return value == 0 ? L("none") : hex(value)
    }

    // MARK: USB-C Power Delivery

    public static func pdo(_ pdo: PowerDataObject) -> String {
        switch pdo.kind {
        case .fixed:
            return [pdo.maxVoltage.map { Format.volts(millivolts: $0, digits: 0) },
                    pdo.maxCurrent.map { Format.amps(milliamps: $0) }].compactMap { $0 }.joined(separator: " · ")
        case .pps, .variable:
            let range = [pdo.minVoltage, pdo.maxVoltage].compactMap { $0 }
                .map { Format.volts(millivolts: $0, digits: 1) }.joined(separator: "–")
            let kind = pdo.kind == .pps ? "PPS " : ""
            return kind + [range, pdo.maxCurrent.map { Format.amps(milliamps: $0) }].compactMap { $0 }.joined(separator: " · ")
        case .battery:
            return [pdo.minVoltage, pdo.maxVoltage].compactMap { $0 }
                .map { Format.volts(millivolts: $0, digits: 1) }.joined(separator: "–")
                + (pdo.maxPower.map { " · " + Format.watts(Double($0) / 1000) } ?? "")
        case .unknown:
            return String(format: "0x%08X", pdo.raw)
        }
    }

    public static func profile(_ pdo: PowerDataObject, position: Int?) -> String {
        var parts: [String] = []
        if let v = pdo.maxVoltage { parts.append(Format.volts(millivolts: v, digits: v % 1000 == 0 ? 0 : 1)) }
        if let i = pdo.maxCurrent { parts.append(Format.amps(milliamps: i)) }
        if let power = pdo.power { parts.append(Format.watts(Double(power) / 1000)) }
        if let position { parts.append(L("profile %lld", position)) }
        return parts.joined(separator: " · ")
    }

    public static func requested(_ contract: PowerDeliveryContract) -> String? {
        guard let current = contract.operatingCurrent else { return nil }
        var text = Format.amps(milliamps: current)
        if let power = contract.power { text += " · " + Format.watts(Double(power) / 1000) }
        return text
    }

    /// "12 / 11" plug-ins / removals.
    public static func counts(_ pd: PowerDeliveryInfo) -> String? {
        guard let attach = pd.attachCount else { return nil }
        let detach = pd.detachCount.map { Format.number(Double($0)) } ?? "–"
        return "\(Format.number(Double(attach))) / \(detach)"
    }
}
