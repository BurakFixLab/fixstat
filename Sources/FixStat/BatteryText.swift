import Foundation
import MacSensors

/// Localized battery state texts shared by both panels.
@available(macOS 14.0, *)
enum BatteryText {
    /// Power flowing in (adapter input) or out (battery) in W.
    static func watts(_ battery: BatteryInfo) -> Double? {
        if battery.externalConnected == true, let input = battery.powerTelemetry?.systemPowerIn, input > 0 {
            return Double(input) / 1000
        }
        return battery.batteryPowerWatts.map(abs)
    }

    static func state(_ battery: BatteryInfo) -> String {
        if battery.fullyCharged == true {
            return String(localized: "Fully charged")
        }
        if battery.isCharging == true {
            if let watts = watts(battery) {
                return String(localized: "Charging · \(Format.watts(watts))")
            }
            return String(localized: "Charging")
        }
        if battery.externalConnected == true {
            return String(localized: "On power adapter · not charging")
        }
        if let watts = watts(battery) {
            return String(localized: "On battery · \(Format.watts(watts))")
        }
        return String(localized: "On battery")
    }

    /// "Full in 38 min" / "2 hr, 10 min remaining", nil when unknown.
    static func time(_ battery: BatteryInfo) -> String? {
        if battery.isCharging == true, let minutes = battery.timeToFull, minutes > 0 {
            return String(localized: "Full in \(Format.minutes(minutes))")
        }
        if battery.externalConnected != true, let minutes = battery.timeToEmpty ?? battery.timeRemaining, minutes > 0 {
            return String(localized: "\(Format.minutes(minutes)) remaining")
        }
        return nil
    }

    static func symbol(_ battery: BatteryInfo?) -> String {
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
