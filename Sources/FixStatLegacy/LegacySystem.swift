import AppKit
import ServiceManagement
import UserNotifications
import FixStatCore

/// Notifications of the AppKit interface: UserNotifications from macOS 10.14 (asks for
/// permission), NSUserNotification on 10.13.
enum LegacyNotifications {
    static func install() {
        AlertManager.sender = { kind, body in send(kind, body: body) }
    }

    /// Whether notifications may be shown (nil: unknown, macOS 10.13 has no such setting).
    static func checkAuthorization(_ completion: @escaping (Bool?) -> Void) {
        guard #available(macOS 10.14, *) else {
            completion(nil)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            DispatchQueue.main.async { completion(allowed) }
        }
    }

    static func requestAuthorization(_ completion: @escaping (Bool?) -> Void) {
        guard #available(macOS 10.14, *) else {
            completion(nil)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            checkAuthorization(completion)
        }
    }

    private static func send(_ kind: AlertManager.Kind, body: String) {
        if #available(macOS 10.14, *) {
            let content = UNMutableNotificationContent()
            content.title = L("FixStat")
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: "fixstat.\(kind.rawValue)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error { NSLog("FixStat: notification failed: %@", error.localizedDescription) }
            }
        } else {
            legacyDeliver(kind, body: body)
        }
    }

    /// macOS 10.13: the notification API before UserNotifications.
    @available(macOS, deprecated: 11.0)
    private static func legacyDeliver(_ kind: AlertManager.Kind, body: String) {
        let notification = NSUserNotification()
        notification.identifier = "fixstat.\(kind.rawValue).\(Date().timeIntervalSince1970)"
        notification.title = L("FixStat")
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }
}

/// "Open at login" for the AppKit interface: SMAppService on macOS 13, a per-user launch
/// agent on older systems (no helper app or root needed; loaded by launchd at login).
enum LegacyLoginItem {
    private static let label = "io.github.burakfixlab.fixstat.login"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    /// Returns an error message, or nil on success.
    static func set(_ enabled: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        do {
            if enabled {
                // `open -b` finds FixStat wherever it is installed.
                let agent: [String: Any] = [
                    "Label": label,
                    "ProgramArguments": ["/usr/bin/open", "-b", Bundle.main.bundleIdentifier ?? "io.github.burakfixlab.fixstat"],
                    "RunAtLoad": true,
                    "LimitLoadToSessionType": "Aqua",
                ]
                try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try PropertyListSerialization.data(fromPropertyList: agent, format: .xml, options: 0)
                try data.write(to: agentURL, options: .atomic)
            } else if FileManager.default.fileExists(atPath: agentURL.path) {
                try FileManager.default.removeItem(at: agentURL)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
