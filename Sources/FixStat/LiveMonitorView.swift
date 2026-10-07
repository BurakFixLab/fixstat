import AppKit
import Charts
import MacSensors
import SwiftUI
import UniformTypeIdentifiers
import FixStatCore

/// SwiftUI view of the core `LiveMonitor`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class LiveMonitorModel {
    private(set) var ready = false
    private(set) var channels: [LiveMonitor.Channel] = []
    private(set) var selected: [String] = []
    private(set) var samples: [LiveMonitor.Sample] = []
    private(set) var markers: [Date] = []
    private(set) var interval: TimeInterval = 0.5
    private(set) var recordingStarted: Date?
    private(set) var recordedRows = 0

    @ObservationIgnored let monitor: LiveMonitor

    init(core: MonitorCore) {
        monitor = LiveMonitor(monitor: core)
        monitor.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start() { monitor.start() }
    func stop() { monitor.stop() }

    private func sync() {
        if monitor.ready != ready { ready = monitor.ready }
        if monitor.channels != channels { channels = monitor.channels }
        if monitor.selected != selected { selected = monitor.selected }
        samples = monitor.samples
        if monitor.markers != markers { markers = monitor.markers }
        if monitor.interval != interval { interval = monitor.interval }
        if monitor.recordingStarted != recordingStarted { recordingStarted = monitor.recordingStarted }
        recordedRows = monitor.recording?.count ?? 0
    }
}

/// Pick up to six SMC values and watch them live; mark moments, record and save as CSV.
@available(macOS 14.0, *)
struct LiveMonitorView: View {
    static let windowID = "live-monitor"

    @Environment(Monitor.self) private var monitor
    @State private var model: LiveMonitorModel?
    @State private var search = ""

    var body: some View {
        HSplitView {
            channelList
                .frame(minWidth: 240, idealWidth: 270, maxWidth: 340)
            content
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
        .monospacedDigit()
        .onAppear {
            let model = model ?? LiveMonitorModel(core: monitor.core)
            self.model = model
            model.start()
        }
        .onDisappear { model?.stop() }
    }

    // MARK: Channels

    private var channelList: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            if let model, model.ready {
                List {
                    ForEach(LiveMonitor.Group.allCases, id: \.self) { group in
                        let channels = filtered(model.channels.filter { $0.group == group })
                        if !channels.isEmpty {
                            Section(LiveMonitor.groupTitle(group)) {
                                ForEach(channels, id: \.id) { channel in
                                    channelRow(channel, model: model)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            }
        }
    }

    private func filtered(_ channels: [LiveMonitor.Channel]) -> [LiveMonitor.Channel] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return channels }
        return channels.filter {
            $0.title.localizedCaseInsensitiveContains(query) || ($0.detail?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func channelRow(_ channel: LiveMonitor.Channel, model: LiveMonitorModel) -> some View {
        let isOn = model.selected.contains(channel.id)
        let full = model.selected.count >= LiveMonitor.maximumChannels
        return Button {
            model.monitor.toggle(channel.id)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                Text(verbatim: channel.title).lineLimit(1)
                Spacer(minLength: 4)
                if let detail = channel.detail {
                    Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isOn && full)
    }

    // MARK: Charts

    @ViewBuilder
    private var content: some View {
        if let model {
            VStack(alignment: .leading, spacing: 10) {
                toolbar(model)
                if model.selected.isEmpty {
                    Text("Pick up to six values on the left.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: Design.cardSpacing) {
                            ForEach(model.selected, id: \.self) { id in
                                if let channel = model.channels.first(where: { $0.id == id }) {
                                    LiveChannelChart(channel: channel, samples: model.samples, markers: model.markers)
                                }
                            }
                        }
                    }
                }
                Text("Values as the SMC reports them, a few times a second: slow changes show, microsecond dips and ripple do not (that needs an oscilloscope).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
    }

    private func toolbar(_ model: LiveMonitorModel) -> some View {
        HStack(spacing: 10) {
            Picker("Rate", selection: Binding(get: { model.interval }, set: { model.monitor.setInterval($0) })) {
                Text("4 per second").tag(0.25)
                Text("2 per second").tag(0.5)
                Text("1 per second").tag(1.0)
            }
            .fixedSize()
            Button("Mark", systemImage: "flag") { model.monitor.addMarker() }
                .help(Text("Adds a numbered marker (M1, M2 …) to the charts and the CSV, e.g. when you plug in the charger."))
            Spacer()
            if let started = model.recordingStarted {
                Label {
                    Text("Recording \(Format.minutesSeconds(Date().timeIntervalSince(started)))")
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(TemperatureColor.hot)
                }
                Button("Stop and save…") { save(model.monitor.stopRecording(), name: "live-recording") }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Save as CSV…") { save(model.monitor.windowCSV(), name: "live-window") }
                    .help(Text("Saves the last ten minutes shown here."))
                    .disabled(model.samples.isEmpty)
                Button("Record", systemImage: "record.circle") { model.monitor.startRecording() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func save(_ csv: String?, name: String) {
        guard let csv else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "fixstat-\(name)-\(Format.isoDay(Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One channel: current value, min / max over the window, and its line.
@available(macOS 14.0, *)
private struct LiveChannelChart: View {
    let channel: LiveMonitor.Channel
    let samples: [LiveMonitor.Sample]
    let markers: [Date]

    var body: some View {
        let points = samples.compactMap { sample in sample.values[channel.id].map { (sample.time, $0) } }
        let values = points.map(\.1)
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: channel.title).font(.headline)
                if let detail = channel.detail {
                    Text(verbatim: detail).font(.caption.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
                if let low = values.min(), let high = values.max(), high > low {
                    Text(verbatim: LiveMonitor.format(low, channel.unit) + " … " + LiveMonitor.format(high, channel.unit))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(verbatim: values.last.map { LiveMonitor.format($0, channel.unit) } ?? "–")
                    .font(.title3.weight(.semibold))
            }
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.0), y: .value("Value", point.1))
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                ForEach(Array(markers.enumerated()), id: \.offset) { index, marker in
                    if let first = points.first?.0, marker >= first {
                        RuleMark(x: .value("Marker", marker))
                            .foregroundStyle(TemperatureColor.warm)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .leading) {
                                Text(verbatim: "M\(index + 1)").font(.caption2).foregroundStyle(TemperatureColor.warm)
                            }
                    }
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let date = value.as(Date.self) { Text(Format.timeWithSeconds(date)) } }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(LiveMonitor.axisLabel(v, channel.unit)) } }
                }
            }
            .frame(height: 110)
        }
    }
}
