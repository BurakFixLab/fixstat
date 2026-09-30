import Foundation
import MacSensors

/// Checks at launch whether the Mac lost power without a normal shutdown while the
/// battery still showed charge — typical for a weak cell or a failing battery — and
/// posts a notification once per boot.
public enum UnexpectedShutdown {
    public struct Finding {
        public let boot: Date
        public let chargeBefore: Double?
        public let causeCode: Int?
    }

    /// Shutdown cause codes that point at the battery.
    public static let batteryCauses: Set<Int> = [-60, -79, -103, -104]

    public static let notifiedKey = "unexpectedShutdown.notifiedBoot"

    /// Runs the check in the background; the notification is posted on the main thread.
    public static func checkAtLaunch() {
        DispatchQueue.global(qos: .utility).async {
            guard let finding = detect(now: Date()) else { return }
            DispatchQueue.main.async { notify(finding) }
        }
    }

    /// Only for a boot in the last hour (FixStat opening at login), so old events are
    /// not reported again and again.
    public static func detect(now: Date) -> Finding? {
        let records = OffStateDrain.bootRecords()
        guard let index = records.lastIndex(where: \.isBoot) else { return nil }
        let boot = records[index].date
        guard now.timeIntervalSince(boot) < 3600,
              UserDefaults.standard.double(forKey: notifiedKey) != boot.timeIntervalSince1970 else { return nil }
        // A shutdown record right before the boot: macOS shut down normally.
        if index > 0, !records[index - 1].isBoot { return nil }

        let cause = CrashHistory.shutdownEvents(days: 1)
            .filter { abs($0.date.timeIntervalSince(boot)) < 900 }
            .min { abs($0.date.timeIntervalSince(boot)) < abs($1.date.timeIntervalSince(boot)) }?.code
        if cause == 3 || cause == 5 { return nil } // power button held, or normal
        // A kernel panic is reported by the panic history, not as a battery problem.
        if CrashHistory.panics().contains(where: { abs($0.date.timeIntervalSince(boot)) < 900 }) { return nil }

        let log = Command.pmsetLog()
        let period = OffStateDrain.fromLog(log, records: Array(records[...index]), fullChargeCapacity: nil)
            .last { abs($0.boot.timeIntervalSince(boot)) < 60 }
        let charge = period?.chargeBefore
        guard (charge ?? 0) > 5 || batteryCauses.contains(cause ?? 0) else { return nil }
        return Finding(boot: boot, chargeBefore: charge, causeCode: cause)
    }

    public static func notify(_ finding: Finding) {
        UserDefaults.standard.set(finding.boot.timeIntervalSince1970, forKey: notifiedKey)
        var body = finding.chargeBefore.map {
            L("The Mac turned off unexpectedly while the battery showed %@. The battery may be faulty.", Format.percent($0))
        } ?? L("The Mac turned off unexpectedly. The battery may be faulty.")
        if let code = finding.causeCode {
            body += " " + L("Shutdown cause %lld: %@", code, CrashText.shutdownMeaning(ShutdownEvent.meanings[code]))
        }
        AlertManager.postOnce(.unexpectedShutdown, body: body)
    }
}
