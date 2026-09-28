import AppKit
import Charts
import MacSensors
import SwiftUI
import UniformTypeIdentifiers

/// Battery history window: charge, current and long-term health.
struct HistoryView: View {
    static let windowID = "battery-history"

    enum Range: Int, CaseIterable, Identifiable {
        case day, week, month

        var id: Int { rawValue }
        var duration: TimeInterval { [86_400, 7 * 86_400, 30 * 86_400][rawValue] }
        /// Bucket size so that every range has at most ~360 points.
        var bucket: TimeInterval { [240, 1_800, 7_200][rawValue] }
        var title: LocalizedStringKey { ["Last 24 hours", "Last 7 days", "Last 30 days"][rawValue] }
    }

    @Environment(Monitor.self) private var monitor
    @State private var range = Range.day
    @State private var samples: [BatteryHistorySample] = []
    @State private var health: [BatteryHealthRecord] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                HistoryExportMenu(range: range)
            }
            if samples.isEmpty {
                ContentUnavailableView {
                    Label("No battery history yet", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("FixStat records the battery once a minute while it is running. Samples are kept for 30 days, daily health values indefinitely.")
                }
            } else {
                summary
                chargeChart
                currentChart
            }
            healthChart
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 520)
        .monospacedDigit()
        .onAppear(perform: load)
        .onChange(of: range) { load() }
    }

    private func load() {
        let since = Date().addingTimeInterval(-range.duration)
        samples = BatteryHistoryStore.bucketed(monitor.history.samples(since: since), interval: range.bucket)
        health = monitor.history.healthRecords()
    }

    // MARK: Summary

    private var summary: some View {
        let charging = samples.filter { $0.amperage > 0 }.map { Double($0.amperage) }
        let discharging = samples.filter { $0.amperage < 0 }.map { Double($0.amperage) }
        let temperatures = samples.compactMap(\.temperature)
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return HStack(spacing: 8) {
            Tile(title: "Average charge current", value: mean(charging).map { Format.milliamps(Int($0)) } ?? "–")
            Tile(title: "Average discharge current", value: mean(discharging).map { Format.milliamps(Int($0)) } ?? "–")
            Tile(title: "Highest temperature", value: temperatures.max().map { Format.temperature($0) } ?? "–")
        }
    }

    // MARK: Charts

    private var xDomain: ClosedRange<Date> {
        let now = Date()
        return now.addingTimeInterval(-range.duration)...now
    }

    /// One bucket's share of the plot width (≈ 600 pt), at least 1 pt.
    private var barWidth: CGFloat {
        max(1, 600 * range.bucket / range.duration)
    }

    private var chargeChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Charge")
            Chart(samples, id: \.time) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value("Charge", sample.stateOfCharge))
                    .foregroundStyle(Color.accentColor.opacity(0.15))
                LineMark(x: .value("Time", sample.time), y: .value("Charge", sample.stateOfCharge))
                    .foregroundStyle(Color.accentColor)
                // A line needs two points; show the samples themselves while there are few.
                if samples.count < 30 {
                    PointMark(x: .value("Time", sample.time), y: .value("Charge", sample.stateOfCharge))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(20)
                }
            }
            .chartXScale(domain: xDomain)
            .chartXAxis { AxisMarks(preset: .aligned) }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.percent(value.as(Double.self) ?? 0)) }
                }
            }
            .frame(height: 130)
            .accessibilityLabel(Text("Charge"))
        }
    }

    private var currentChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Current")
                Spacer()
                Label("Charging", systemImage: "circle.fill").foregroundStyle(TemperatureColor.cool)
                Label("Discharging", systemImage: "circle.fill").foregroundStyle(TemperatureColor.hot)
            }
            .font(.caption)
            .labelStyle(LegendLabelStyle())
            Chart(samples, id: \.time) { sample in
                BarMark(x: .value("Time", sample.time, unit: .second),
                        y: .value("Current", sample.amperage),
                        width: .fixed(barWidth))
                    .foregroundStyle(sample.amperage >= 0 ? TemperatureColor.cool : TemperatureColor.hot)
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.5))
            }
            .chartXScale(domain: xDomain)
            .chartXAxis { AxisMarks(preset: .aligned) }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.milliamps(value.as(Int.self) ?? 0)) }
                }
            }
            .frame(height: 130)
            .accessibilityLabel(Text("Current"))
        }
    }

    private var healthChart: some View {
        let points = health.compactMap { record in record.date.map { ($0, record.health) } }
        let lowest = points.map(\.1).min() ?? 80
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Health")
                Spacer()
                if let first = health.first?.date {
                    Text("Since \(first.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if points.isEmpty {
                Text("No health values recorded yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                Chart(points, id: \.0) { point in
                    LineMark(x: .value("Day", point.0, unit: .day), y: .value("Health", point.1))
                        .foregroundStyle(Color.accentColor)
                    PointMark(x: .value("Day", point.0, unit: .day), y: .value("Health", point.1))
                        .foregroundStyle(Color.accentColor)
                }
                .chartXScale(domain: healthDomain(points.map(\.0)))
                .chartXAxis { AxisMarks(preset: .aligned) }
                .chartYScale(domain: max(0, (lowest - 5).rounded(.down))...100)
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { Text(Format.percent(value.as(Double.self) ?? 0)) }
                    }
                }
                .frame(height: 110)
                .accessibilityLabel(Text("Health"))
            }
        }
    }
}

/// At least the last 7 days, padded by half a day, so a short history does not
/// zoom the axis into hours.
private func healthDomain(_ dates: [Date]) -> ClosedRange<Date> {
    let now = Date()
    let start = min(dates.min() ?? now, now.addingTimeInterval(-7 * 86_400)).addingTimeInterval(-43_200)
    let end = max(dates.max() ?? now, now).addingTimeInterval(43_200)
    return start...end
}

/// Small coloured dot + text for chart legends.
private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// Exports the history of the selected range (CSV: samples; JSON: samples + daily health).
private struct HistoryExportMenu: View {
    @Environment(Monitor.self) private var monitor
    let range: HistoryView.Range

    var body: some View {
        Menu("Export history") {
            Button("CSV…") { export(csv: true) }
            Button("JSON…") { export(csv: false) }
        }
        .fixedSize()
    }

    private struct Payload: Encodable {
        let app = "FixStat"
        let model: String
        let samples: [BatteryHistorySample]
        let health: [BatteryHealthRecord]
    }

    private func export(csv: Bool) {
        let samples = monitor.history.samples(since: Date().addingTimeInterval(-range.duration))
        let data: Data
        if csv {
            let iso = ISO8601DateFormatter()
            let header = "time,stateOfCharge,health,amperage,voltage,temperature,isCharging,externalConnected"
            let rows = samples.map { sample -> String in
                var fields = BatteryHistoryStore.csvLine(sample).split(separator: ",", omittingEmptySubsequences: false)
                fields[0] = Substring(iso.string(from: sample.time))
                return fields.joined(separator: ",")
            }
            data = Data(([header] + rows).joined(separator: "\n").appending("\n").utf8)
        } else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let json = try? encoder.encode(Payload(model: monitor.system.model, samples: samples,
                                                        health: monitor.history.healthRecords())) else { return }
            data = json
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        let date = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "FixStat-battery-history-\(monitor.system.model)-\(date).\(csv ? "csv" : "json")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
