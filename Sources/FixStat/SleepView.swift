import MacSensors
import SwiftUI
import FixStatCore

/// Sleep / wake analysis from the power management log.
@available(macOS 14.0, *)
struct SleepView: View {
    static let windowID = "sleep"

    @Environment(Monitor.self) private var monitor
    @State private var idleTester: IdlePowerTester?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
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
        .onAppear { if idleTester == nil { idleTester = IdlePowerTester(core: monitor.core) } }
    }

    private func reload() async {
        monitor.lastSleepAnalysis = await Task.detached { SleepAnalysis.read() }.value
    }

    @ViewBuilder
    private func content(_ a: SleepAnalysis) -> some View {
        let off = monitor.offPeriods(a)
        let findings = SleepText.findings(a) + SleepText.offFindings(off)

        // Header: what the log covers, refresh.
        HStack(alignment: .firstTextBaseline) {
            if let from = a.from, let to = a.to {
                Text("Power log · \(from.formatted(date: .abbreviated, time: .shortened)) – \(to.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
        }

        // One line: the verdict.
        FindingRow(text: findings.isEmpty ? String(localized: "No sleep or wake problems found.")
                                          : String(localized: "\(findings.count) things to check, listed below."),
                   problem: !findings.isEmpty)
            .font(.title3)

        // Four numbers that matter, the rest in one quiet line.
        HStack(spacing: Design.cardSpacing) {
            MetricTile(title: "Sleeps", value: Format.number(Double(a.sleeps.count)))
            MetricTile(title: "Wakes", value: Format.number(Double(a.wakes.count)))
            MetricTile(title: "Dark wakes", value: Format.number(Double(a.darkWakes.count)))
            MetricTile(title: "Drain while asleep", value: a.sleepDrain.map { SleepText.drain($0.percentPerHour) } ?? "–")
        }
        Text("Battery ran empty \(a.lowPowerSleeps) · Failures \(a.failures.count) · Average wake \(a.averageWakeTime.map { Format.seconds($0) } ?? "–") · Low battery warnings \(a.lowBatteryWarnings)")
            .font(.callout)
            .foregroundStyle(.secondary)

        if !findings.isEmpty {
            Card {
                CardHeader("To check", systemImage: "exclamationmark.triangle")
                ForEach(Array(findings.enumerated()), id: \.offset) { index, finding in
                    if index > 0 { Divider() }
                    FindingRow(text: finding)
                }
            }
        }

        if monitor.profile.hasBattery {
            DrainCard(report: monitor.core.drainReport(analysis: a), tester: idleTester)
        }

        HStack(alignment: .top, spacing: Design.cardSpacing) {
            reasonCard("Wake reasons", a.reasons(.wake))
            reasonCard("Dark wake reasons", a.reasons(.darkWake))
        }

        offCard(off)

        if !a.preventingNow.isEmpty || !a.preventers.isEmpty {
            Card {
                CardHeader("What keeps the Mac awake", systemImage: "cup.and.saucer")
                if !a.preventingNow.isEmpty {
                    CardRow(title: Text("Now"), value: a.preventingNow.joined(separator: ", "))
                }
                ForEach(a.preventers, id: \.process) { p in
                    CardRow(title: Text(verbatim: p.process),
                            value: String(localized: "\(p.count) times, longest \(Format.duration(Double(p.longestSeconds)))"))
                }
            }
        }

        if !a.slowDrivers.isEmpty {
            Card {
                CardHeader("Slow drivers during sleep / wake", systemImage: "tortoise")
                ForEach(a.slowDrivers, id: \.driver) { d in
                    CardRow(title: Text(verbatim: d.driver),
                            value: String(localized: "\(d.count)× · up to \(Format.number(Double(d.maxMilliseconds))) ms"))
                }
            }
        }

        Card {
            CardHeader("Settings", systemImage: "gearshape")
            ForEach(SleepText.settingRows(a.settings), id: \.0) { r in
                CardRow(title: Text(verbatim: r.0), value: r.1)
            }
        }

        Card {
            DisclosureGroup {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
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
                .font(.callout)
                .padding(.top, 6)
            } label: {
                Label("Recent events (\(min(a.events.count, 40)))", systemImage: "list.bullet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func offCard(_ periods: [OffPeriod]) -> some View {
        Card {
            CardHeader("While shut down", systemImage: "power")
            if let summary = OffStateDrain.summary(periods) {
                Text(verbatim: SleepText.offSummary(summary))
            }
            if periods.isEmpty {
                Text("No shutdowns with a known charge in the log yet.").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                ForEach(Array(periods.reversed().enumerated()), id: \.offset) { _, p in
                    GridRow {
                        Text(p.shutdown.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                        Text(verbatim: Format.duration(p.hours * 3600))
                        Text(verbatim: SleepText.chargeChange(p))
                        Text(verbatim: p.averageCurrent.map { SleepText.milliamps($0) } ?? "")
                        Text(verbatim: SleepText.source(p)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(p.isUsable ? .primary : .tertiary)
                }
            }
            Text("Measured: FixStat saved the battery gauge at power off and read it after the boot (needs FixStat to open at login). From log: whole percentages from the power log, so short periods are rough.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Reasons with a count; the raw reason from the log in small mono under the plain one.
    private func reasonCard(_ title: LocalizedStringKey, _ counts: [SleepAnalysis.Count]) -> some View {
        Card {
            CardHeader(title, systemImage: "bolt.horizontal")
            if counts.isEmpty {
                Text("none").foregroundStyle(.secondary)
            }
            ForEach(Array(counts.enumerated()), id: \.offset) { index, c in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: "\(c.count)×")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: SleepText.category(c.name) ?? c.name)
                        if SleepText.category(c.name) != nil {
                            Text(verbatim: c.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }
}

/// Drain detective: drain while asleep / shut down and what it points to.
@available(macOS 14.0, *)
private struct DrainCard: View {
    let report: DrainReport
    let tester: IdlePowerTester?

    var body: some View {
        let headline = DrainText.headline(report)
        Card {
            CardHeader("Drain detective", systemImage: "magnifyingglass")
            Label(headline.text, systemImage: headline.problem == true ? "exclamationmark.triangle.fill"
                  : headline.problem == false ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(headline.problem == true ? TemperatureColor.hot
                                 : headline.problem == false ? TemperatureColor.cool : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(Array(DrainText.rows(report).enumerated()), id: \.offset) { _, row in
                CardRow(title: Text(verbatim: row.0), value: row.1)
            }
            Text(verbatim: DrainText.guide).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tester {
                IdlePowerSection(tester: tester)
            }
        }
    }
}

/// Idle power with the display off, compared with good Macs of the model.
@available(macOS 14.0, *)
private struct IdlePowerSection: View {
    let tester: IdlePowerTester

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if tester.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(verbatim: tester.progress)
                }
                Button("Stop") { tester.cancel() }
            } else {
                if let failure = tester.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(TemperatureColor.hot)
                }
                if let result = tester.result {
                    ForEach(Array(DrainText.idlePowerRows(result).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(verbatim: row.0).foregroundStyle(.secondary)
                            Text(verbatim: row.1)
                        }
                    }
                    if let verdict = tester.verdict {
                        Label(verdict.text, systemImage: verdict.problem == true ? "exclamationmark.triangle.fill"
                              : verdict.problem == false ? "checkmark.seal.fill" : "info.circle")
                            .foregroundStyle(verdict.problem == true ? TemperatureColor.hot
                                             : verdict.problem == false ? TemperatureColor.cool : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Button(DrainText.idlePowerButton) { tester.start() }
            }
        }
    }
}

/// SwiftUI view of the core `IdlePowerRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class IdlePowerTester {
    private(set) var running = false
    private(set) var progress = ""
    private(set) var failure: String?
    private(set) var result: IdlePowerResult?
    private(set) var verdict: (text: String, problem: Bool?)?

    @ObservationIgnored private let runner: IdlePowerRunner
    @ObservationIgnored private let core: MonitorCore

    init(core: MonitorCore) {
        self.core = core
        runner = IdlePowerRunner(monitor: core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    func start() { runner.start() }
    func cancel() { runner.cancel() }

    private func sync() {
        running = runner.isRunning
        progress = running ? DrainText.idlePowerProgress(runner) : ""
        if case let .failed(message) = runner.state { failure = message } else { failure = nil }
        if core.lastIdlePower != result {
            result = core.lastIdlePower
            verdict = result.map { DrainText.idlePowerVerdict($0, reference: core.powerReference, model: core.system.model) }
        }
    }
}
