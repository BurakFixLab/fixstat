import Foundation
import MacSensors
import OSLog
import UserNotifications
import FixStatCore

/// Delivers `AlertManager` notifications through UserNotifications.
@available(macOS 14.0, *)
extension AlertManager {
    nonisolated private static let log = Logger(subsystem: "io.github.burakfixlab.fixstat", category: "alerts")

    /// Makes UserNotifications the delivery for all alerts.
    static func installUserNotificationSender() {
        sender = { kind, body in send(kind, body: body) }
    }

    /// Whether macOS currently lets FixStat show notifications.
    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static func send(_ kind: Kind, body: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "FixStat")
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "fixstat.\(kind.rawValue)", content: content, trigger: nil)
        log.info("posting \(kind.rawValue, privacy: .public) notification")
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Self.log.error("notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
