import Foundation
import MacSensors

/// Localized SSD texts (window and PDF report).
public enum SSDText {
    public static let usedWarning = 80
    public static let usedCritical = 100

    public static func healthFindings(_ h: NVMeHealth) -> [String] {
        var findings: [String] = []
        if h.criticalWarning != 0 {
            findings.append(L("The SSD reports a critical warning (code %lld).", h.criticalWarning))
        }
        if h.percentageUsed >= usedCritical {
            findings.append(L("Rated endurance used up (%lld %%).", h.percentageUsed))
        } else if h.percentageUsed >= usedWarning {
            findings.append(L("Most of the rated endurance is used (%lld %%).", h.percentageUsed))
        }
        if h.availableSpare < h.availableSpareThreshold {
            findings.append(L("Spare blocks below threshold (%lld %%).", h.availableSpare))
        }
        if h.mediaErrors > 0 {
            findings.append(L("%@ media / data integrity errors recorded.", Format.number(h.mediaErrors)))
        }
        return findings
    }

    public static func healthRows(_ h: NVMeHealth) -> [(String, String)] {
        [
            (L("Endurance used"), Format.percent(Double(h.percentageUsed))),
            (L("Available spare"), Format.percent(Double(h.availableSpare))),
            (L("Data written"), Format.bytes(h.bytesWritten)),
            (L("Data read"), Format.bytes(h.bytesRead)),
            (L("Power-on hours"), Format.number(h.powerOnHours)),
            (L("Power cycles"), Format.number(h.powerCycles)),
            (L("Unsafe shutdowns"), Format.number(h.unsafeShutdowns)),
            (L("Media errors"), Format.number(h.mediaErrors)),
            (L("Error log entries"), Format.number(h.errorLogEntries)),
            (L("Temperature"), h.temperature.map { Format.temperature($0, digits: 0) } ?? "–"),
        ]
    }

    public static func finding(_ f: SSDStressTest.Result.Finding) -> String {
        switch f {
        case let .dataMismatch(chunks, first):
            return L("Data read back did not match in %lld blocks (first at %@) — failing NAND or controller", chunks, Format.bytes(Double(first) * 8_388_608))
        case let .ioErrors(count):
            return L("%lld read / write errors", count)
        case let .slowChunks(count, worst):
            return L("%lld blocks were very slow (worst %@ ms) — possible weak NAND or retries", count, Format.number(worst * 1000))
        case let .smartMediaErrorsIncreased(by):
            return L("SMART media errors increased by %@ during the test", Format.number(by))
        case let .smartErrorLogIncreased(by):
            return L("SMART error log grew by %@ entries during the test", Format.number(by))
        case .stoppedEarly:
            return L("Test was stopped before the planned duration")
        case .notEnoughSpace:
            return L("Not enough free space for the test")
        }
    }

    public static func resultRows(_ r: SSDStressTest.Result) -> [(String, String)] {
        var rows: [(String, String)] = [
            (L("Tested"), Format.bytes(r.testedBytes)),
            (L("Write speed"), r.writeSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
            (L("Read speed"), r.readSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
        ]
        let writes = r.timings.map(\.write).sorted()
        let reads = r.timings.compactMap(\.read).sorted()
        if let worst = writes.last {
            rows.append((L("Slowest block write"), "\(Format.number(worst * 1000)) ms"))
        }
        if let worst = reads.last {
            rows.append((L("Slowest block read"), "\(Format.number(worst * 1000)) ms"))
        }
        return rows
    }
}
