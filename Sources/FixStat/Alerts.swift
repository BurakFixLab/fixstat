import Foundation
import MacSensors
import OSLog
import UserNotifications

/// Posts macOS notifications for sustained problems. Each alert needs its
/// condition to hold for a while and is repeated at most every 15 minutes.
@MainActor
final class AlertManager {
    enum Kind: String, CaseIterable {
        case chipTemperature, batteryTemperature, cellImbalance, chargingStopped

        var enabledKey: String { "alerts.\(rawValue)" }

        /// How long the condition must hold before notifying.
        var delay: TimeInterval {
            switch self {
            case .chipTemperature: 30
            case .batteryTemperature: 30
            case .cellImbalance: 60
            case .chargingStopped: 180
            }
        }
    }

    static let repeatInterval: TimeInterval = 15 * 60
    static let batteryTemperatureLimit = 45.0
    static let chargingStoppedBelow = 75.0

    private var since: [Kind: Date] = [:]
    private var lastSent: [Kind: Date] = [:]

    static var enabled: Bool { UserDefaults.standard.bool(forKey: Pref.alertsEnabled) }

    nonisolated private static let log = Logger(subsystem: "io.github.burakfixlab.fixstat", category: "alerts")

    /// Whether macOS currently lets FixStat show notifications.
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func evaluate(monitor: Monitor, now: Date = Date()) {
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
            String(localized: "Chip temperature \(Format.temperature(hottestChip ?? 0)) (limit \(Format.temperature(chipLimit, digits: 0)))")
        }

        let batteryTemperature = battery?.temperature ?? 0
        check(.batteryTemperature, batteryTemperature >= Self.batteryTemperatureLimit, now: now) {
            String(localized: "Battery temperature \(Format.temperature(batteryTemperature)) (limit \(Format.temperature(Self.batteryTemperatureLimit, digits: 0)))")
        }

        let imbalanceLimit = defaults.integer(forKey: Pref.cellImbalanceThreshold)
        let spread = battery?.cellImbalance ?? 0
        let onBattery = battery?.externalConnected == false
        check(.cellImbalance, onBattery && imbalanceLimit > 0 && spread > imbalanceLimit, now: now) {
            String(localized: "Cell spread \(Format.millivolts(spread)) on battery (limit \(Format.millivolts(imbalanceLimit)))")
        }

        let stopped = battery?.externalConnected == true && battery?.isCharging == false
            && battery?.fullyCharged != true && (battery?.stateOfCharge ?? 100) < Self.chargingStoppedBelow
        check(.chargingStopped, stopped, now: now) {
            String(localized: "Power adapter connected but not charging at \(Format.percent(battery?.stateOfCharge ?? 0))")
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
        post(kind, body: message())
    }

    private func post(_ kind: Kind, body: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "FixStat")
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fixstat.\(kind.rawValue)", content: content, trigger: nil)
        Self.log.info("posting \(kind.rawValue, privacy: .public) notification")
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
