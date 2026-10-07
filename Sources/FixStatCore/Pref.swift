import Foundation

/// UserDefaults keys and defaults for all preferences.
public enum Pref {
    public static let menuBarBatteryIcon = "menuBar.batteryIcon"
    public static let menuBarBatteryPercent = "menuBar.batteryPercent"
    public static let menuBarCPUTemperature = "menuBar.cpuTemperature"
    public static let technicianMode = "technicianMode"
    /// "system", "light" or "dark" (AppearancePreference).
    public static let appearance = "appearance"
    public static let warmThreshold = "threshold.warm"
    public static let hotThreshold = "threshold.hot"
    public static let cellImbalanceThreshold = "threshold.cellImbalance"
    public static let updateInterval = "updateInterval"
    /// Notifications master switch and the CPU/GPU alert temperature.
    public static let alertsEnabled = "alerts.enabled"
    public static let alertChipTemperature = "alerts.chipTemperatureLimit"
    public static let defaultAlertChipTemperature = 90.0
    /// Shop name and footer note printed on the PDF report.
    public static let reportShopName = "report.shopName"
    public static let reportNote = "report.note"
    /// Full serial numbers in exported reports (masked by default).
    public static let reportFullSerial = "report.fullSerial" // privacy:allow (a preference key name)

    /// Whether exported reports carry full serial numbers.
    public static var reportsShowSerial: Bool { UserDefaults.standard.bool(forKey: reportFullSerial) }
    /// Newline-separated sensor uids hidden from the lists.
    public static let hiddenSensors = "hiddenSensors"
    /// Dock icon also while no FixStat window is open (see DockIcon).
    public static let showInDock = "dock.alwaysShow"
    /// Ask GitHub once a day for a newer release (`UpdateChecker`).
    public static let checkForUpdates = "update.check"

    public static let defaultWarm = 45.0
    public static let defaultHot = 55.0
    public static let defaultCellImbalance = 50
    public static let defaultInterval = 2.0
    public static let intervals: [Double] = [1, 2, 5, 10]

    public static func register() {
        UserDefaults.standard.register(defaults: [
            menuBarBatteryIcon: true,
            menuBarBatteryPercent: true,
            menuBarCPUTemperature: true,
            technicianMode: false,
            appearance: "system",
            warmThreshold: defaultWarm,
            hotThreshold: defaultHot,
            cellImbalanceThreshold: defaultCellImbalance,
            updateInterval: defaultInterval,
            hiddenSensors: "",
            showInDock: false,
            checkForUpdates: true,
            reportFullSerial: false,
            alertsEnabled: false,
            alertChipTemperature: defaultAlertChipTemperature,
        ])
    }

    public static func hiddenSet(_ raw: String) -> Set<String> {
        Set(raw.split(separator: "\n").map(String.init))
    }

    public static func hiddenString(_ set: Set<String>) -> String {
        set.sorted().joined(separator: "\n")
    }
}
