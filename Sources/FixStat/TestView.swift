import Charts
import MacSensors
import SwiftUI

/// Post-repair stress test window.
struct TestView: View {
    static let windowID = "stress-test"

    @Environment(TestRunner.self) private var runner
    @AppStorage(Pref.hotThreshold) private var hot = Pref.defaultHot
    @State private var minutes = 5.0
    @State private var cpu = true
    @State private var gpu = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Loads the CPU and GPU for a few minutes and checks temperatures, cell voltages and power delivery. Run it after a repair with the case closed, on a desk.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            controls
            if runner.state != .idle {
                liveValues
                chart
            }
            if let result = runner.result {
                ResultView(result: result)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 600, minHeight: 520)
        .monospacedDigit()
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Duration", selection: $minutes) {
                ForEach([2.0, 5.0, 10.0], id: \.self) { value in
                    Text(verbatim: Duration.seconds(value * 60).formatted(.units(allowed: [.minutes], width: .abbreviated)))
                        .tag(value)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(runner.state == .running)
            Toggle("CPU", isOn: $cpu).disabled(runner.state == .running)
            Toggle("GPU", isOn: $gpu).disabled(runner.state == .running)
            Spacer()
            if runner.state == .running {
                Button("Stop", role: .cancel) { runner.stop() }
            } else {
                Button("Start test") { runner.start(duration: minutes * 60, cpu: cpu, gpu: gpu) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!cpu && !gpu)
            }
        }
    }

    private var liveValues: some View {
        let last = runner.samples.last
        return VStack(alignment: .leading, spacing: 8) {
            if runner.state == .running {
                ProgressView(value: min(runner.elapsed / runner.duration, 1))
                Text("\(Format.minutesSeconds(max(runner.duration - runner.elapsed, 0))) remaining")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Tile(title: "CPU", value: last?.cpu.map { Format.temperature($0) } ?? "–")
                Tile(title: "GPU", value: last?.gpu.map { Format.temperature($0) } ?? "–")
                Tile(title: "Battery", value: last?.battery.map { Format.temperature($0) } ?? "–")
                Tile(title: "Current", value: last?.amperage.map { Format.milliamps($0) } ?? "–")
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionTitle(title: "Temperature")
                Spacer()
                Label("CPU", systemImage: "circle.fill").foregroundStyle(TemperatureColor.hot)
                Label("GPU", systemImage: "circle.fill").foregroundStyle(TemperatureColor.cool)
            }
            .font(.caption)
            Chart {
                ForEach(runner.samples, id: \.time) { sample in
                    if let cpu = sample.cpu {
                        LineMark(x: .value("Time", sample.time), y: .value("°C", cpu), series: .value("Group", "cpu"))
                            .foregroundStyle(TemperatureColor.hot)
                    }
                    if let gpu = sample.gpu {
                        LineMark(x: .value("Time", sample.time), y: .value("°C", gpu), series: .value("Group", "gpu"))
                            .foregroundStyle(TemperatureColor.cool)
                    }
                }
                RuleMark(y: .value("Hot", hot))
                    .foregroundStyle(TemperatureColor.warm.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartXScale(domain: 0...max(runner.duration, 1))
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.minutesSeconds(value.as(Double.self) ?? 0)) }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.degrees(value.as(Double.self) ?? 0)) }
                }
            }
            .frame(height: 160)
        }
    }
}

/// Summary and findings after a test.
struct ResultView: View {
    let result: StressTestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let problems = result.findings.filter { $0 != .stoppedEarly }
            if problems.isEmpty {
                Label("No problems found", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.hot)
            }
            ForEach(Array(result.findings.enumerated()), id: \.offset) { _, finding in
                Text(verbatim: "• " + TestText.finding(finding))
                    .font(.callout)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                ForEach(TestText.summaryRows(result), id: \.0) { row in
                    GridRow {
                        Text(verbatim: row.0).foregroundStyle(.secondary)
                        Text(verbatim: row.1).font(.callout.monospaced())
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Localized texts for test results (shared by the window and the PDF report).
enum TestText {
    static func finding(_ finding: StressTestResult.Finding) -> String {
        switch finding {
        case let .highChipTemperature(group, celsius, limit):
            let name = group == "gpu" ? "GPU" : "CPU"
            return String(localized: "\(name) reached \(Format.temperature(celsius)) (limit \(Format.temperature(limit, digits: 0)))")
        case let .highBatteryTemperature(celsius, limit):
            return String(localized: "Battery reached \(Format.temperature(celsius)) (limit \(Format.temperature(limit, digits: 0)))")
        case let .cellVoltageSag(cell, millivolts, limit):
            return String(localized: "Cell \(cell) dropped to \(Format.volts(millivolts: millivolts, digits: 3)) under load (limit \(Format.volts(millivolts: limit, digits: 1)))")
        case let .cellImbalance(millivolts, limit):
            return String(localized: "Cell spread reached \(Format.millivolts(millivolts)) under load (limit \(Format.millivolts(limit)))")
        case let .adapterDeficit(average):
            return String(localized: "On the power adapter the battery was still discharging (average \(Format.milliamps(average))) — adapter, cable or charging circuit may be weak")
        case .stoppedEarly:
            return String(localized: "Test was stopped before the planned duration")
        }
    }

    static func summaryRows(_ r: StressTestResult) -> [(String, String)] {
        var rows: [(String, String)] = [
            (String(localized: "Duration"), Format.minutesSeconds(r.duration)),
            (String(localized: "Highest CPU temperature"), r.maxCPU.map { Format.temperature($0) } ?? "–"),
            (String(localized: "Highest GPU temperature"), r.maxGPU.map { Format.temperature($0) } ?? "–"),
            (String(localized: "Highest SSD temperature"), r.maxSSD.map { Format.temperature($0) } ?? "–"),
            (String(localized: "Highest battery temperature"), r.maxBattery.map { Format.temperature($0) } ?? "–"),
            (String(localized: "Time at or above hot threshold"), Format.minutesSeconds(r.secondsAboveHot)),
        ]
        if let v = r.minCellVoltage {
            rows.append((String(localized: "Lowest cell voltage"), Format.volts(millivolts: v, digits: 3)))
        }
        if let s = r.maxCellSpread {
            rows.append((String(localized: "Largest cell spread"), Format.millivolts(s)))
        }
        if let a = r.socStart, let b = r.socEnd {
            rows.append((String(localized: "Battery charge"), "\(Format.percent(a)) → \(Format.percent(b))"))
        }
        if let c = r.averageCurrent {
            rows.append((String(localized: "Average battery current"), Format.milliamps(c)))
        }
        return rows
    }
}
