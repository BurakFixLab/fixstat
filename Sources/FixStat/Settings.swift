import Foundation

/// UserDefaults keys and defaults for all preferences.
@available(macOS 14.0, *)
enum Pref {
    static let menuBarBatteryIcon = "menuBar.batteryIcon"
    static let menuBarBatteryPercent = "menuBar.batteryPercent"
    static let menuBarCPUTemperature = "menuBar.cpuTemperature"
    static let technicianMode = "technicianMode"
    /// "system", "light" or "dark" (AppearancePreference).
    static let appearance = "appearance"
    static let warmThreshold = "threshold.warm"
    static let hotThreshold = "threshold.hot"
    static let cellImbalanceThreshold = "threshold.cellImbalance"
    static let updateInterval = "updateInterval"
    /// Notifications master switch and the CPU/GPU alert temperature.
    static let alertsEnabled = "alerts.enabled"
    static let alertChipTemperature = "alerts.chipTemperatureLimit"
    static let defaultAlertChipTemperature = 90.0
    /// Shop name and footer note printed on the PDF report.
    static let reportShopName = "report.shopName"
    static let reportNote = "report.note"
    /// Newline-separated sensor uids hidden from the lists.
    static let hiddenSensors = "hiddenSensors"

    static let defaultWarm = 45.0
    static let defaultHot = 55.0
    static let defaultCellImbalance = 50
    static let defaultInterval = 2.0
    static let intervals: [Double] = [1, 2, 5, 10]

    static func register() {
        UserDefaults.standard.register(defaults: [
            menuBarBatteryIcon: true,
            menuBarBatteryPercent: true,
            menuBarCPUTemperature: true,
            technicianMode: false,
            appearance: AppearancePreference.system.rawValue,
            warmThreshold: defaultWarm,
            hotThreshold: defaultHot,
            cellImbalanceThreshold: defaultCellImbalance,
            updateInterval: defaultInterval,
            hiddenSensors: "",
            alertsEnabled: false,
            alertChipTemperature: defaultAlertChipTemperature,
        ])
    }

    static func hiddenSet(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    static func hiddenString(_ set: Set<String>) -> String {
        set.sorted().joined(separator: "\n")
    }
}
