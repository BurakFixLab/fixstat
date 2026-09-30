import Foundation
import MacSensors

/// Localized battery state texts shared by both panels.
public enum BatteryText {
    /// Power flowing in (adapter input) or out (battery) in W.
    public static func watts(_ battery: BatteryInfo) -> Double? {
        if battery.externalConnected == true, let input = battery.powerTelemetry?.systemPowerIn, input > 0 {
            return Double(input) / 1000
        }
        return battery.batteryPowerWatts.map(abs)
    }

    public static func state(_ battery: BatteryInfo) -> String {
        if battery.fullyCharged == true {
            return L("Fully charged")
        }
        if battery.isCharging == true {
            if let watts = watts(battery) {
                return L("Charging · %@", Format.watts(watts))
            }
            return L("Charging")
        }
        if battery.externalConnected == true {
            return L("On power adapter · not charging")
        }
        if let watts = watts(battery) {
            return L("On battery · %@", Format.watts(watts))
        }
        return L("On battery")
    }

    /// "Full in 38 min" / "2 hr, 10 min remaining", nil when unknown.
    public static func time(_ battery: BatteryInfo) -> String? {
        if battery.isCharging == true, let minutes = battery.timeToFull, minutes > 0 {
            return L("Full in %@", Format.minutes(minutes))
        }
        if battery.externalConnected != true, let minutes = battery.timeToEmpty ?? battery.timeRemaining, minutes > 0 {
            return L("%@ remaining", Format.minutes(minutes))
        }
        return nil
    }

    /// Technician header line: rated adapter power and the current input power.
    public static func adapter(_ battery: BatteryInfo?) -> String {
        guard let battery, battery.externalConnected == true else {
            return L("No power adapter")
        }
        let now = battery.powerTelemetry?.systemPowerIn.flatMap { $0 > 0 ? Format.watts(Double($0) / 1000, digits: 1) : nil }
        let rated = battery.adapter?.ratedWatts.map { Format.watts(Double($0)) }
        let kind = battery.adapter?.description?.lowercased().contains("pd") == true ? "USB-C" : nil
        switch (rated, now) {
        case let (rated?, now?):
            let adapter = [rated, kind].compactMap { $0 }.joined(separator: " ")
            return L("Adapter %@ · now %@", adapter, now)
        case let (rated?, nil):
            return L("Adapter %@", rated)
        case let (nil, now?):
            return L("Power adapter · now %@", now)
        default:
            return L("Power adapter connected")
        }
    }

    public static func symbol(_ battery: BatteryInfo?) -> String {
        guard let battery else { return "battery.0percent" }
        if battery.isCharging == true || battery.fullyCharged == true { return "battery.100percent.bolt" }
        switch battery.stateOfCharge ?? 0 {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
