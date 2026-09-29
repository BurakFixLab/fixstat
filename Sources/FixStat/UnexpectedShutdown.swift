import Foundation
import MacSensors

/// Checks at launch whether the Mac lost power without a normal shutdown while the
/// battery still showed charge — typical for a weak cell or a failing battery — and
/// posts a notification once per boot.
@available(macOS 14.0, *)
enum UnexpectedShutdown {
    struct Finding: Sendable {
        let boot: Date
        let chargeBefore: Double?
        let causeCode: Int?
    }

    /// Shutdown cause codes that point at the battery.
    static let batteryCauses: Set<Int> = [-60, -79, -103, -104]

    static let notifiedKey = "unexpectedShutdown.notifiedBoot"

    @MainActor
    static func checkAtLaunch() {
        Task.detached(priority: .utility) {
            guard let finding = detect(now: Date()) else { return }
            await MainActor.run { notify(finding) }
        }
    }

    /// Only for a boot in the last hour (FixStat opening at login), so old events are
    /// not reported again and again.
    static func detect(now: Date) -> Finding? {
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

    @MainActor
    static func notify(_ finding: Finding) {
        UserDefaults.standard.set(finding.boot.timeIntervalSince1970, forKey: notifiedKey)
        var body = finding.chargeBefore.map {
            String(localized: "The Mac turned off unexpectedly while the battery showed \(Format.percent($0)). The battery may be faulty.")
        } ?? String(localized: "The Mac turned off unexpectedly. The battery may be faulty.")
        if let code = finding.causeCode {
            body += " " + String(localized: "Shutdown cause \(code): \(CrashText.shutdownMeaning(ShutdownEvent.meanings[code]))")
        }
        AlertManager.postOnce(.unexpectedShutdown, body: body)
    }
}
