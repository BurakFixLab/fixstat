import Foundation
import MacSensors

/// Decides when to notify about sustained problems. Each alert needs its condition to
/// hold for a while and is repeated at most every 15 minutes. Delivery is up to the
/// interface (`sender`): UserNotifications on new systems, NSUserNotification on old ones.
public final class AlertManager {
    public enum Kind: String, CaseIterable {
        case chipTemperature, batteryTemperature, cellImbalance, chargingStopped
        /// Sent once, at launch after such a shutdown (see `UnexpectedShutdown`).
        case unexpectedShutdown
        /// A newer FixStat release (see `UpdateChecker`); its own setting, not the alerts switch.
        case updateAvailable

        public var enabledKey: String { "alerts.\(rawValue)" }

        /// Only offered on Macs with a battery.
        public var needsBattery: Bool { self != .chipTemperature && self != .updateAvailable }

        /// How long the condition must hold before notifying.
        public var delay: TimeInterval {
            switch self {
            case .chipTemperature: return 30
            case .batteryTemperature: return 30
            case .cellImbalance: return 60
            case .chargingStopped: return 180
            case .unexpectedShutdown, .updateAvailable: return 0
            }
        }
    }

    public static let repeatInterval: TimeInterval = 15 * 60
    public static let batteryTemperatureLimit = 45.0
    public static let chargingStoppedBelow = 75.0

    /// Delivers a notification (kind, body); set by the interface at launch. Main thread.
    public nonisolated(unsafe) static var sender: ((Kind, String) -> Void)?

    private var since: [Kind: Date] = [:]
    private var lastSent: [Kind: Date] = [:]

    public init() {}

    public static var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.alertsEnabled) }

    public func evaluate(monitor: MonitorCore, now: Date = Date()) {
        guard Self.enabled else {
            since.removeAll()
            return
        }
        let defaults = UserDefaults.standard
        let battery = monitor.battery

        let chipLimit = defaults.double(forKey: Pref.alertChipTemperature)
        let hottestChip = monitor.sensors
            .filter { $0.group == .cpu || $0.group == .gpu }
            .compactMap(monitor.value(of:))
            .max()
        check(.chipTemperature, (hottestChip ?? 0) >= chipLimit, now: now) {
            L("Chip temperature %@ (limit %@)", Format.temperature(hottestChip ?? 0),
              Format.temperature(chipLimit, digits: 0))
        }

        let batteryTemperature = battery?.temperature ?? 0
        check(.batteryTemperature, batteryTemperature >= Self.batteryTemperatureLimit, now: now) {
            L("Battery temperature %@ (limit %@)", Format.temperature(batteryTemperature),
              Format.temperature(Self.batteryTemperatureLimit, digits: 0))
        }

        let imbalanceLimit = defaults.integer(forKey: Pref.cellImbalanceThreshold)
        let spread = battery?.cellImbalance ?? 0
        let onBattery = battery?.externalConnected == false
        check(.cellImbalance, onBattery && imbalanceLimit > 0 && spread > imbalanceLimit, now: now) {
            L("Cell spread %@ on battery (limit %@)", Format.millivolts(spread), Format.millivolts(imbalanceLimit))
        }

        let stopped = battery?.externalConnected == true && battery?.isCharging == false
            && battery?.fullyCharged != true && (battery?.stateOfCharge ?? 100) < Self.chargingStoppedBelow
        check(.chargingStopped, stopped, now: now) {
            L("Power adapter connected but not charging at %@", Format.percent(battery?.stateOfCharge ?? 0))
        }
    }

    private func check(_ kind: Kind, _ condition: Bool, now: Date, message: () -> String) {
        guard condition, UserDefaults.standard.object(forKey: kind.enabledKey) as? Bool ?? true else {
            since[kind] = nil
            return
        }
        let start = since[kind] ?? now
        since[kind] = start
        guard now.timeIntervalSince(start) >= kind.delay else { return }
        if let last = lastSent[kind], now.timeIntervalSince(last) < Self.repeatInterval { return }
        lastSent[kind] = now
        Self.sender?(kind, message())
    }

    /// Posts a one-off notification (no delay or repeat logic), if notifications and
    /// this kind are enabled.
    public static func postOnce(_ kind: Kind, body: String) {
        guard enabled, UserDefaults.standard.object(forKey: kind.enabledKey) as? Bool ?? true else { return }
        sender?(kind, body)
    }
}
