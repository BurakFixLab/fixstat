import AppKit
import Charts
import MacSensors
import SwiftUI
import UniformTypeIdentifiers
import FixStatCore

/// Battery history window: charge, current and long-term health.
@available(macOS 14.0, *)
struct HistoryView: View {
    static let windowID = "battery-history"

    enum Range: Int, CaseIterable, Identifiable {
        case hour1, hours3, hours6, hours12, day, week, month

        var id: Int { rawValue }

        var duration: TimeInterval {
            let hour: TimeInterval = 3_600
            switch self {
            case .hour1: return hour
            case .hours3: return 3 * hour
            case .hours6: return 6 * hour
            case .hours12: return 12 * hour
            case .day: return 24 * hour
            case .week: return 7 * 24 * hour
            case .month: return 30 * 24 * hour
            }
        }

        /// Bucket size so that every range has at most ~360 points. Up to 6 h the
        /// raw minute samples are shown.
        var bucket: TimeInterval {
            switch self {
            case .hour1, .hours3, .hours6: return 60
            case .hours12: return 120
            case .day: return 240
            case .week: return 1_800
            case .month: return 7_200
            }
        }

        /// "1 hour", "12 hours", "1 day", "7 days" in the user's language.
        var title: String {
            Duration.seconds(duration).formatted(.units(allowed: [.days, .hours], width: .wide))
        }
    }

    @Environment(Monitor.self) private var monitor
    @State private var range: Range
    @State private var samples: [BatteryHistorySample] = []
    @State private var health: [BatteryHealthRecord] = []
    /// Time under the pointer in the charge / current charts.
    @State private var hoverTime: Date?
    /// Day under the pointer in the health chart.
    @State private var hoverDay: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text(verbatim: $0.title).tag($0) }
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
        // Reload when the range changes and then every minute (new samples).
        .task(id: range) {
            while !Task.isCancelled {
                load()
                try? await Task.sleep(for: .seconds(Monitor.historyInterval))
            }
        }
    }

    init(initialRange: Range = .day) {
        _range = State(initialValue: initialRange)
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

    /// The sample closest to the pointer, if the pointer is over a chart.
    private var hoveredSample: BatteryHistorySample? {
        guard let hoverTime, !samples.isEmpty else { return nil }
        return samples.min { abs($0.time.timeIntervalSince(hoverTime)) < abs($1.time.timeIntervalSince(hoverTime)) }
    }

    /// The daily health record closest to the pointer.
    private var hoveredHealth: BatteryHealthRecord? {
        guard let hoverDay else { return nil }
        return health
            .filter { $0.date != nil }
            .min { abs($0.date!.timeIntervalSince(hoverDay)) < abs($1.date!.timeIntervalSince(hoverDay)) }
    }

    /// Transparent layer that reports the date under the pointer (nil when it leaves).
    private func hoverOverlay(_ proxy: ChartProxy, update: @escaping (Date?) -> Void) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let plotFrame = proxy.plotFrame else { return }
                        let x = location.x - geometry[plotFrame].origin.x
                        update(proxy.value(atX: x, as: Date.self))
                    case .ended:
                        update(nil)
                    }
                }
        }
    }

    /// One bucket's share of the plot width (≈ 600 pt), at least 1 pt.
    private var barWidth: CGFloat {
        max(1, 600 * range.bucket / range.duration)
    }

    private var chargeChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Charge")
            Chart {
                ForEach(samples, id: \.time) { sample in
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
                if let sample = hoveredSample {
                    RuleMark(x: .value("Time", sample.time))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                            SampleCard(sample: sample, showsDate: range.duration > 86_400)
                        }
                    PointMark(x: .value("Time", sample.time), y: .value("Charge", sample.stateOfCharge))
                        .foregroundStyle(Color.accentColor)
                        .symbolSize(60)
                }
            }
            .chartOverlay { proxy in hoverOverlay(proxy) { hoverTime = $0 } }
            .chartXScale(domain: xDomain)
            .chartXAxis { AxisMarks(preset: .aligned) }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(Format.percent(value.as(Double.self) ?? 0)) }
                }
            }
            .frame(height: 150)
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
            Chart {
                ForEach(samples, id: \.time) { sample in
                    BarMark(x: .value("Time", sample.time, unit: .second),
                            y: .value("Current", sample.amperage),
                            width: .fixed(barWidth))
                        .foregroundStyle(sample.amperage >= 0 ? TemperatureColor.cool : TemperatureColor.hot)
                }
                RuleMark(y: .value("Zero", 0)).foregroundStyle(.secondary.opacity(0.5))
                if let sample = hoveredSample {
                    RuleMark(x: .value("Time", sample.time))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                }
            }
            .chartOverlay { proxy in hoverOverlay(proxy) { hoverTime = $0 } }
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
                Chart {
                    ForEach(points, id: \.0) { point in
                        LineMark(x: .value("Day", point.0, unit: .day), y: .value("Health", point.1))
                            .foregroundStyle(Color.accentColor)
                        PointMark(x: .value("Day", point.0, unit: .day), y: .value("Health", point.1))
                            .foregroundStyle(Color.accentColor)
                    }
                    if let record = hoveredHealth, let date = record.date {
                        RuleMark(x: .value("Day", date, unit: .day))
                            .foregroundStyle(Color.secondary.opacity(0.6))
                            .annotation(position: .top, spacing: 4,
                                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                HealthCard(record: record)
                            }
                    }
                }
                .chartOverlay { proxy in hoverOverlay(proxy) { hoverDay = $0 } }
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

/// Values of one sample, shown above the charts while hovering.
@available(macOS 14.0, *)
private struct SampleCard: View {
    let sample: BatteryHistorySample
    let showsDate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sample.time.formatted(showsDate
                                       ? .dateTime.day().month(.abbreviated).hour().minute()
                                       : .dateTime.hour().minute()))
                .font(.caption.weight(.semibold))
            row("Charge", Format.percent(sample.stateOfCharge))
            row("Current", Format.milliamps(sample.amperage))
            if let temperature = sample.temperature {
                row("Temperature", Format.temperature(temperature))
            }
            Text(sample.isCharging ? "Charging" : (sample.externalConnected ? "On power adapter" : "On battery"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
        }
        .font(.caption)
    }
}

/// Values of one day in the health chart.
@available(macOS 14.0, *)
private struct HealthCard: View {
    let record: BatteryHealthRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.date?.formatted(date: .abbreviated, time: .omitted) ?? record.day)
                .font(.caption.weight(.semibold))
            HStack(spacing: 8) {
                Text("Health").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(Format.percent(record.health, digits: 1))
            }
            if let cycles = record.cycleCount {
                HStack(spacing: 8) {
                    Text("Cycles").foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(Format.number(Double(cycles)))
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}

/// At least the last 7 days, padded by half a day, so a short history does not
/// zoom the axis into hours.
@available(macOS 14.0, *)
private func healthDomain(_ dates: [Date]) -> ClosedRange<Date> {
    let now = Date()
    let start = min(dates.min() ?? now, now.addingTimeInterval(-7 * 86_400)).addingTimeInterval(-43_200)
    let end = max(dates.max() ?? now, now).addingTimeInterval(43_200)
    return start...end
}

/// Small coloured dot + text for chart legends.
@available(macOS 14.0, *)
private struct LegendLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title.foregroundStyle(.secondary)
        }
    }
}

/// Exports the history of the selected range (CSV: samples; JSON: samples + daily health).
@available(macOS 14.0, *)
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
