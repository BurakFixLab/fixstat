import Foundation
import MacSensors

public enum SleepText {
    public static func drain(_ percentPerHour: Double) -> String {
        L("%@ per hour", Format.percent(percentPerHour, digits: 1))
    }

    public static func kind(_ k: SleepAnalysis.Event.Kind) -> String {
        switch k {
        case .sleep: L("Sleep")
        case .wake: L("Wake")
        case .darkWake: L("Dark wake")
        case .failure: L("Failure")
        }
    }

    /// Plain-language group of a pmset wake reason (nil: unknown, show it raw).
    public static func category(_ reason: String) -> String? {
        let r = reason.lowercased()
        if r.contains("lid") { return L("Lid opened") }
        if r.contains("acattach") { return L("Power adapter connected") }
        if r.contains("pwrbtn") || r.contains("power button") { return L("Power button") }
        if r.contains("trackpad") || r.contains("keyboard") { return L("Keyboard or trackpad") }
        if r.contains("rtc") || r.contains("maintenance") || r.contains("sleepservice") {
            return L("Scheduled (maintenance, Power Nap)")
        }
        if r.contains("wifi") || r.contains("wlan") || r.contains("arp") || r.contains("network") || r.contains("bt") {
            return L("Network or Bluetooth")
        }
        if r.contains("usb") || r.contains("xhci") { return L("USB device") }
        if r.contains("useractivity") { return L("User activity") }
        switch reason {
        case "Idle Sleep": return L("Idle sleep")
        case "Clamshell Sleep": return L("Lid closed")
        case "Software Sleep": return L("Sleep chosen by the user")
        case "Low Power Sleep": return L("Battery almost empty")
        case "Maintenance Sleep": return L("Back to sleep after maintenance")
        case "Power Button": return L("Power button")
        default: return nil
        }
    }

    public static func describe(_ reason: String) -> String {
        category(reason).map { "\($0) (\(reason))" } ?? reason
    }

    public static func findings(_ a: SleepAnalysis) -> [String] {
        var result: [String] = []
        if let rate = a.sleepDrain?.percentPerHour, rate > 1 {
            result.append(L("High battery drain while asleep: %@. A healthy Mac usually loses less than 1 %% per hour; check Power Nap, wake for network access and the dark wake reasons.", drain(rate)))
        }
        if a.lowPowerSleeps > 0 {
            result.append(L("The battery ran empty %lld times (macOS forced sleep at a few percent).", a.lowPowerSleeps))
        }
        if !a.failures.isEmpty {
            result.append(L("%lld sleep or wake failures in the log.", a.failures.count))
        }
        if let from = a.from, let to = a.to {
            let days = max(to.timeIntervalSince(from) / 86_400, 1)
            if Double(a.darkWakes.count) / days > 40 {
                result.append(L("Frequent dark wakes: about %lld per day.", Int(Double(a.darkWakes.count) / days)))
            }
        }
        let others = a.preventingNow.filter { $0 != "powerd" }
        if !others.isEmpty {
            result.append(L("Sleep is prevented right now by: %@.", others.joined(separator: ", ")))
        }
        if a.settings["displaysleep"] == "0" {
            result.append(L("The display is set never to turn off."))
        }
        if a.settings["sleep"] == "0" {
            result.append(L("The Mac is set never to sleep."))
        }
        // No sleeps at all: say why, so an empty analysis does not look like a fault.
        if a.sleeps.isEmpty {
            if a.settings["SleepDisabled"] == "1" {
                result.append(L("Sleep is turned off on this Mac (pmset disablesleep 1): it has not slept, so there is nothing to analyse."))
            } else if let from = a.from, let to = a.to, to.timeIntervalSince(from) < 86_400 {
                result.append(L("The power log covers only %@: macOS starts it again after the Mac is erased or its clock is changed.",
                                Format.duration(to.timeIntervalSince(from))))
            }
        }
        return result
    }

    public static func milliamps(_ value: Double) -> String {
        "≈ " + Format.number(value, digits: value < 10 ? 1 : 0) + "\u{00A0}mA"
    }

    public static func chargeChange(_ p: OffPeriod) -> String {
        if let a = p.remainingBefore, let b = p.remainingAfter {
            return Format.milliampHours(a) + " → " + Format.milliampHours(b)
        }
        return [p.chargeBefore, p.chargeAfter].map { $0.map { Format.percent($0) } ?? "–" }.joined(separator: " → ")
    }

    public static func source(_ p: OffPeriod) -> String {
        switch p.source {
        case .measured: L("measured")
        case .log: p.shutdownEstimated ? L("from log, power lost") : L("from log")
        }
    }

    public static func offSummary(_ s: (percentPerHour: Double?, milliamps: Double?, hours: Double)) -> String {
        var parts: [String] = []
        if let p = s.percentPerHour { parts.append(drain(p)) }
        if let mA = s.milliamps { parts.append(milliamps(mA)) }
        parts.append(L("over %@ shut down", Format.duration(s.hours * 3600)))
        return parts.joined(separator: " · ")
    }

    /// A shut-down Mac should lose very little; more than 0.3 %/h (about 7 % a day) over
    /// at least four hours and a drop of at least 3 points is worth a look.
    public static func offFindings(_ periods: [OffPeriod]) -> [String] {
        var result: [String] = []
        let lost = periods.filter { $0.shutdownEstimated && ($0.chargeBefore ?? 0) > 5 }
        if let last = lost.last, let charge = last.chargeBefore {
            result.append(L("The Mac turned off without a normal shutdown %lld times while the battery still showed charge (last time at %@). Unless these were kernel panics or a held power button, the battery may be faulty.", lost.count, Format.percent(charge)))
        }
        return result + drainFindings(periods)
    }

    private static func drainFindings(_ periods: [OffPeriod]) -> [String] {
        guard let s = OffStateDrain.summary(periods), s.hours >= 4, let rate = s.percentPerHour, rate > 0.3 else { return [] }
        // Whole percentages from the log round by up to 1 point at each end: only flag
        // when the drop is large enough, or when FixStat measured it in mAh.
        let usable = periods.filter(\.isUsable)
        let lost = usable.compactMap(\.lostPercent).reduce(0, +)
        guard usable.contains(where: { $0.source == .measured }) || lost >= 3 else { return [] }
        return [L("High drain while shut down: %@. A Mac that is off should lose very little; suspect a leakage current on the board or a battery with high self-discharge.", offSummary(s))]
    }

    public static func settingRows(_ s: [String: String]) -> [(String, String)] {
        func flag(_ key: String) -> String? {
            s[key].map { $0 == "0" ? L("Off") : L("On") }
        }
        func minutes(_ key: String) -> String? {
            s[key].flatMap(Int.init).map { $0 == 0 ? L("never") : Format.minutes($0) }
        }
        let rows: [(String, String?)] = [
            (L("Sleep after"), minutes("sleep")),
            (L("Display off after"), minutes("displaysleep")),
            (L("Power Nap"), flag("powernap")),
            (L("Wake for network access"), flag("womp")),
            (L("Keep network connections (TCP keepalive)"), flag("tcpkeepalive")),
            (L("Standby"), flag("standby")),
            (L("Hibernate mode"), s["hibernatemode"]),
            (L("Low Power Mode"), flag("lowpowermode")),
        ]
        return rows.compactMap { r in r.1.map { (r.0, $0) } }
    }
}
