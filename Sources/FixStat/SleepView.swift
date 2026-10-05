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
        .onAppear { if idleTester == nil { idleTester = IdlePowerTester(core: monitor.core) } }
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

        if monitor.profile.hasBattery {
            DrainCard(report: monitor.core.drainReport(analysis: a), tester: idleTester)
        }

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

/// Drain detective: drain while asleep / shut down and what it points to.
@available(macOS 14.0, *)
private struct DrainCard: View {
    let report: DrainReport
    let tester: IdlePowerTester?

    var body: some View {
        let headline = DrainText.headline(report)
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Drain detective")
            Label(headline.text, systemImage: headline.problem == true ? "exclamationmark.triangle.fill"
                  : headline.problem == false ? "checkmark.seal.fill" : "info.circle")
                .foregroundStyle(headline.problem == true ? TemperatureColor.hot
                                 : headline.problem == false ? TemperatureColor.cool : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(DrainText.rows(report).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: row.0).foregroundStyle(.secondary)
                        Text(verbatim: row.1)
                    }
                }
            }
            Text(verbatim: DrainText.guide).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let tester {
                IdlePowerSection(tester: tester)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
