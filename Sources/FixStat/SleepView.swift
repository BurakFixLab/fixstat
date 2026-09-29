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

        let findings = SleepText.findings(a)
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
