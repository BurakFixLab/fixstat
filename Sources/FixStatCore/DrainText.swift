import Foundation
import MacSensors

/// Texts of the drain detective (sleep window, PDF report).
public enum DrainText {
    /// The verdict and whether it is a problem (nil: no verdict yet).
    public static func headline(_ r: DrainReport) -> (text: String, problem: Bool?) {
        switch r.conclusion {
        case .noData:
            return (L("No measurement yet. Unplug the adapter and let the Mac sleep for at least an hour (overnight is best) while FixStat runs. For the shutdown measurement, shut it down for at least an hour; FixStat must open at login."), nil)
        case .normal:
            return (L("Battery drain while asleep and shut down is normal."), false)
        case .software:
            return (L("The drain while asleep comes from the Mac waking up (dark wakes): software, settings or a device that wakes it, not the board."), true)
        case let .battery(cell):
            return (L("Cell %lld loses charge by itself: the battery, not the board.", cell + 1), true)
        case .hardware(alwaysOn: true?):
            return (L("High drain without wakes, also while shut down: suspect the always-on rails (G3H / AON) or the battery pack. Confirm with a current meter and a thermal camera."), true)
        case .hardware(alwaysOn: false?):
            return (L("High drain only while asleep, without wakes: suspect a rail powered in sleep (memory, S2R) or a device that stays powered. Confirm with a current meter and a thermal camera."), true)
        case .hardware(alwaysOn: nil):
            return (L("High drain while asleep without wakes: suspect a leak on the board. Shut the Mac down for an hour to narrow it down, and confirm with a current meter and a thermal camera."), true)
        }
    }

    static func level(_ level: DrainReport.Level) -> String {
        switch level {
        case .normal: return L("normal")
        case .elevated: return L("elevated")
        case .high: return L("high")
        }
    }

    static func summary(_ s: DrainReport.Summary) -> String {
        L("%@ (%@; median of %lld, %@ in total)", SleepText.milliamps(s.milliamps), level(s.level), s.segments,
          Format.duration(s.hours * 3600))
    }

    public static func rows(_ r: DrainReport) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let sleep = r.sleep { rows.append((L("Drain while asleep (measured)"), summary(sleep))) }
        if let off = r.off { rows.append((L("Drain while shut down (measured)"), summary(off))) }
        if r.sleep != nil {
            rows.append((L("Dark wakes while asleep"), L("%lld · %@ awake", r.darkWakes, Format.duration(Double(r.darkWakeSeconds)))))
        }
        for finding in r.cellFindings {
            rows.append((L("Cell %lld", finding.cell + 1),
                         L("%@ lost beyond the other cells", Format.milliampHours(Int(finding.extraMilliampHours.rounded())))
                            + (finding.maybeBalancing ? " " + L("(highest charged cell: may be cell balancing)") : "")))
        }
        if !r.wakeSettings.isEmpty {
            rows.append((L("Settings that wake the Mac"), r.wakeSettings.joined(separator: ", ")))
        }
        if !r.preventers.isEmpty {
            rows.append((L("Keep the Mac awake"), r.preventers.prefix(4).joined(separator: ", ")))
        }
        return rows
    }

    /// How the levels are judged.
    public static var guide: String {
        L("Rough guide until reference values per model exist: asleep below %@, shut down below %@ is normal. Only sleeps and shutdowns of at least an hour on battery count.",
          SleepText.milliamps(DrainReport.sleepElevated), SleepText.milliamps(DrainReport.offElevated))
    }
}
