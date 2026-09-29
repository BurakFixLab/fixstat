import MacSensors
import SwiftUI

/// Sleep / wake analysis from the power management log.
struct SleepView: View {
    static let windowID = "sleep"

    @Environment(Monitor.self) private var monitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let a = monitor.lastSleepAnalysis {
                    content(a)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 560)
        .monospacedDigit()
        .task { await reload() }
    }

    private func reload() async {
        monitor.lastSleepAnalysis = await Task.detached { SleepAnalysis.read() }.value
    }

    @ViewBuilder
    private func content(_ a: SleepAnalysis) -> some View {
        HStack {
            if let from = a.from, let to = a.to {
                Text("Power log from \(from.formatted(date: .abbreviated, time: .shortened)) to \(to.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh") { Task { await reload() } }
        }
        .font(.callout)

        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
            Tile(title: "Sleeps", value: Format.number(Double(a.sleeps.count)))
            Tile(title: "Wakes", value: Format.number(Double(a.wakes.count)))
            Tile(title: "Dark wakes", value: Format.number(Double(a.darkWakes.count)))
            Tile(title: "Drain while asleep", value: a.sleepDrain.map { SleepText.drain($0.percentPerHour) } ?? "–")
            Tile(title: "Battery ran empty", value: Format.number(Double(a.lowPowerSleeps)))
            Tile(title: "Sleep / wake failures", value: Format.number(Double(a.failures.count)))
            Tile(title: "Average wake time", value: a.averageWakeTime.map { Format.seconds($0) } ?? "–")
            Tile(title: "Low battery warnings", value: Format.number(Double(a.lowBatteryWarnings)))
        }

        let off = monitor.offPeriods(a)
        let findings = SleepText.findings(a) + SleepText.offFindings(off)
        VStack(alignment: .leading, spacing: 6) {
            if findings.isEmpty {
                Label("No sleep or wake problems found.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(TemperatureColor.cool)
                    .font(.headline)
            }
            ForEach(Array(findings.enumerated()), id: \.offset) { _, finding in
                Label(finding, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        HStack(alignment: .top, spacing: 24) {
            countList("Wake reasons", a.reasons(.wake))
            countList("Dark wake reasons", a.reasons(.darkWake))
        }

        offSection(off)

        if !a.preventingNow.isEmpty || !a.preventers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: "What keeps the Mac awake")
                if !a.preventingNow.isEmpty {
                    Text("Now: \(a.preventingNow.joined(separator: ", "))").font(.callout)
                }
                ForEach(a.preventers, id: \.process) { p in
                    row(p.process, String(localized: "\(p.count) times, longest \(Format.duration(Double(p.longestSeconds)))"))
                }
            }
        }

        if !a.slowDrivers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle(title: "Slow drivers during sleep / wake")
                ForEach(a.slowDrivers, id: \.driver) { d in
                    row(d.driver, String(localized: "\(d.count)× · up to \(Format.number(Double(d.maxMilliseconds))) ms"))
                }
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Settings")
            ForEach(SleepText.settingRows(a.settings), id: \.0) { r in row(r.0, r.1) }
        }

        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Recent events")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(Array(a.events.suffix(40).reversed().enumerated()), id: \.offset) { _, e in
                    GridRow {
                        Text(e.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Text(verbatim: SleepText.kind(e.kind))
                        Text(verbatim: SleepText.describe(e.reason)).lineLimit(1)
                        Text(verbatim: [e.charge.map { Format.percent(Double($0)) },
                                        e.onBattery.map { $0 ? String(localized: "battery") : String(localized: "adapter") }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        Text(verbatim: e.duration.map { Format.duration(Double($0)) } ?? "").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func offSection(_ periods: [OffPeriod]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "While shut down")
            if let summary = OffStateDrain.summary(periods) {
                Text(verbatim: SleepText.offSummary(summary))
                    .font(.callout.weight(.semibold))
            }
            if periods.isEmpty {
                Text("No shutdowns with a known charge in the log yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(Array(periods.reversed().enumerated()), id: \.offset) { _, p in
                    GridRow {
                        Text(p.shutdown.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Text(verbatim: Format.duration(p.hours * 3600))
                        Text(verbatim: SleepText.chargeChange(p))
                        Text(verbatim: p.averageCurrent.map { SleepText.milliamps($0) } ?? "")
                        Text(verbatim: SleepText.source(p)).foregroundStyle(.secondary)
                    }
                    .opacity(p.isUsable ? 1 : 0.5)
                }
            }
            .font(.caption)
            Text("Measured: FixStat saved the battery gauge at power off and read it after the boot (needs FixStat to open at login). From log: whole percentages from the power log, so short periods are rough.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func countList(_ title: LocalizedStringKey, _ counts: [SleepAnalysis.Count]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: title)
            if counts.isEmpty {
                Text("none").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(counts, id: \.name) { c in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "\(c.count)×").frame(width: 34, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: SleepText.category(c.name) ?? c.name)
                        if SleepText.category(c.name) != nil {
                            Text(verbatim: c.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: title).frame(width: 220, alignment: .leading)
            Text(verbatim: value).foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

enum SleepText {
    static func drain(_ percentPerHour: Double) -> String {
        String(localized: "\(Format.percent(percentPerHour, digits: 1)) per hour")
    }

    static func kind(_ k: SleepAnalysis.Event.Kind) -> String {
        switch k {
        case .sleep: String(localized: "Sleep")
        case .wake: String(localized: "Wake")
        case .darkWake: String(localized: "Dark wake")
        case .failure: String(localized: "Failure")
        }
    }

    /// Plain-language group of a pmset wake reason (nil: unknown, show it raw).
    static func category(_ reason: String) -> String? {
        let r = reason.lowercased()
        if r.contains("lid") { return String(localized: "Lid opened") }
        if r.contains("acattach") { return String(localized: "Power adapter connected") }
        if r.contains("pwrbtn") || r.contains("power button") { return String(localized: "Power button") }
        if r.contains("trackpad") || r.contains("keyboard") { return String(localized: "Keyboard or trackpad") }
        if r.contains("rtc") || r.contains("maintenance") || r.contains("sleepservice") {
            return String(localized: "Scheduled (maintenance, Power Nap)")
        }
        if r.contains("wifi") || r.contains("wlan") || r.contains("arp") || r.contains("network") || r.contains("bt") {
            return String(localized: "Network or Bluetooth")
        }
        if r.contains("usb") || r.contains("xhci") { return String(localized: "USB device") }
        if r.contains("useractivity") { return String(localized: "User activity") }
        switch reason {
        case "Idle Sleep": return String(localized: "Idle sleep")
        case "Clamshell Sleep": return String(localized: "Lid closed")
        case "Software Sleep": return String(localized: "Sleep chosen by the user")
        case "Low Power Sleep": return String(localized: "Battery almost empty")
        case "Maintenance Sleep": return String(localized: "Back to sleep after maintenance")
        case "Power Button": return String(localized: "Power button")
        default: return nil
        }
    }

    static func describe(_ reason: String) -> String {
        category(reason).map { "\($0) (\(reason))" } ?? reason
    }

    static func findings(_ a: SleepAnalysis) -> [String] {
        var result: [String] = []
        if let rate = a.sleepDrain?.percentPerHour, rate > 1 {
            result.append(String(localized: "High battery drain while asleep: \(drain(rate)). A healthy Mac usually loses less than 1 % per hour; check Power Nap, wake for network access and the dark wake reasons."))
        }
        if a.lowPowerSleeps > 0 {
            result.append(String(localized: "The battery ran empty \(a.lowPowerSleeps) times (macOS forced sleep at a few percent)."))
        }
        if !a.failures.isEmpty {
            result.append(String(localized: "\(a.failures.count) sleep or wake failures in the log."))
        }
        if let from = a.from, let to = a.to {
            let days = max(to.timeIntervalSince(from) / 86_400, 1)
            if Double(a.darkWakes.count) / days > 40 {
                result.append(String(localized: "Frequent dark wakes: about \(Int(Double(a.darkWakes.count) / days)) per day."))
            }
        }
        let others = a.preventingNow.filter { $0 != "powerd" }
        if !others.isEmpty {
            result.append(String(localized: "Sleep is prevented right now by: \(others.joined(separator: ", "))."))
        }
        if a.settings["displaysleep"] == "0" {
            result.append(String(localized: "The display is set never to turn off."))
        }
        if a.settings["sleep"] == "0" {
            result.append(String(localized: "The Mac is set never to sleep."))
        }
        return result
    }

    static func milliamps(_ value: Double) -> String {
        "≈ " + Format.number(value, digits: value < 10 ? 1 : 0) + "\u{00A0}mA"
    }

    static func chargeChange(_ p: OffPeriod) -> String {
        if let a = p.remainingBefore, let b = p.remainingAfter {
            return Format.milliampHours(a) + " → " + Format.milliampHours(b)
        }
        return [p.chargeBefore, p.chargeAfter].map { $0.map { Format.percent($0) } ?? "–" }.joined(separator: " → ")
    }

    static func source(_ p: OffPeriod) -> String {
        switch p.source {
        case .measured: String(localized: "measured")
        case .log: p.shutdownEstimated ? String(localized: "from log, power lost") : String(localized: "from log")
        }
    }

    static func offSummary(_ s: (percentPerHour: Double?, milliamps: Double?, hours: Double)) -> String {
        var parts: [String] = []
        if let p = s.percentPerHour { parts.append(drain(p)) }
        if let mA = s.milliamps { parts.append(milliamps(mA)) }
        parts.append(String(localized: "over \(Format.duration(s.hours * 3600)) shut down"))
        return parts.joined(separator: " · ")
    }

    /// A shut-down Mac should lose very little; more than 0.3 %/h (about 7 % a day) over
    /// at least four hours and a drop of at least 3 points is worth a look.
    static func offFindings(_ periods: [OffPeriod]) -> [String] {
        var result: [String] = []
        let lost = periods.filter { $0.shutdownEstimated && ($0.chargeBefore ?? 0) > 5 }
        if let last = lost.last, let charge = last.chargeBefore {
            result.append(String(localized: "The Mac turned off without a normal shutdown \(lost.count) times while the battery still showed charge (last time at \(Format.percent(charge))). Unless these were kernel panics or a held power button, the battery may be faulty."))
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
        return [String(localized: "High drain while shut down: \(offSummary(s)). A Mac that is off should lose very little; suspect a leakage current on the board or a battery with high self-discharge.")]
    }

    static func settingRows(_ s: [String: String]) -> [(String, String)] {
        func flag(_ key: String) -> String? {
            s[key].map { $0 == "0" ? String(localized: "Off") : String(localized: "On") }
        }
        func minutes(_ key: String) -> String? {
            s[key].flatMap(Int.init).map { $0 == 0 ? String(localized: "never") : Format.minutes($0) }
        }
        let rows: [(String, String?)] = [
            (String(localized: "Sleep after"), minutes("sleep")),
            (String(localized: "Display off after"), minutes("displaysleep")),
            (String(localized: "Power Nap"), flag("powernap")),
            (String(localized: "Wake for network access"), flag("womp")),
            (String(localized: "Keep network connections (TCP keepalive)"), flag("tcpkeepalive")),
            (String(localized: "Standby"), flag("standby")),
            (String(localized: "Hibernate mode"), s["hibernatemode"]),
            (String(localized: "Low Power Mode"), flag("lowpowermode")),
        ]
        return rows.compactMap { r in r.1.map { (r.0, $0) } }
    }
}
