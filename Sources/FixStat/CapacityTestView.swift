import AppKit
import Charts
import MacSensors
import SwiftUI
import UniformTypeIdentifiers
import FixStatCore

/// SwiftUI view of the core `CapacityRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class CapacityTestRunner {
    typealias State = CapacityRunner.State
    typealias Load = CapacityRunner.Load

    private(set) var state = State.idle
    private(set) var samples: [CapacitySample] = []
    private(set) var result: CapacityResult?
    private(set) var target = 20.0

    @ObservationIgnored private let runner: CapacityRunner
    @ObservationIgnored private let monitor: Monitor

    init(monitor: Monitor) {
        self.monitor = monitor
        runner = CapacityRunner(monitor: monitor.core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
        runner.bringToFront = {
            MainActor.assumeIsolated {
                NSApp.activate()
                NSApp.windows.first { $0.identifier?.rawValue.contains(CapacityTestView.windowID) == true }?
                    .makeKeyAndOrderFront(nil)
            }
        }
        sync()
    }

    var elapsed: TimeInterval { runner.elapsed }
    var live: CapacityResult { runner.live }
    func remaining(_ live: CapacityResult) -> TimeInterval? { runner.remaining(live) }
    func start(target: Double, load: Load) { runner.start(target: target, load: load) }
    func stop() { runner.stop() }
    func csv() -> Data { runner.csv() }

    private func sync() {
        if runner.state != state { state = runner.state }
        if runner.samples != samples { samples = runner.samples }
        if runner.target != target { target = runner.target }
        if runner.result != result {
            result = runner.result
            monitor.lastCapacityResult = runner.result
        }
    }
}

@available(macOS 14.0, *)
struct CapacityTestView: View {
    static let windowID = "capacity"

    @Environment(CapacityTestRunner.self) private var runner
    @Environment(Monitor.self) private var monitor
    @State private var target = 20.0
    @State private var load = CapacityTestRunner.Load.medium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    CardHeader("Battery capacity test", systemImage: "battery.50percent")
                    Text("Discharges the battery under a steady load from the current charge down to the chosen level and compares the charge actually delivered with what the battery gauge reports. Start fully charged; the test takes one to several hours. The Mac stays awake and the display stays on.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    controls.padding(.top, 4)
                    loadLegend
                    if target == 0 && !busy {
                        Label("At 0 % macOS puts the Mac to sleep or turns it off by itself. The measurements are saved while the test runs; if the Mac turns off — also early, as a weak battery does — the result appears here the next time FixStat opens. Full discharges wear the battery, so use them sparingly.",
                              systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                switch runner.state {
                case .waitingForUnplug:
                    Label("Unplug the power adapter to start.", systemImage: "powerplug")
                        .font(.headline)
                case .settling:
                    Label("Measuring the idle voltage…", systemImage: "hourglass")
                    liveView
                case .running:
                    liveView
                default:
                    EmptyView()
                }
                if let result = runner.result {
                    CapacityResultView(result: result)
                    HStack {
                        Spacer()
                        Button("Save samples (CSV)…") { saveCSV() }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 560)
        .monospacedDigit()
    }

    private var busy: Bool { [.waitingForUnplug, .settling, .running].contains(runner.state) }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Stop at", selection: $target) {
                ForEach([50.0, 20.0, 10.0, 0.0], id: \.self) { Text(Format.percent($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(busy)
            Picker("Load", selection: $load) {
                Text("Light load").tag(CapacityTestRunner.Load.light)
                Text("Medium").tag(CapacityTestRunner.Load.medium)
                Text("Heavy").tag(CapacityTestRunner.Load.heavy)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(busy)
            Spacer()
            if busy {
                Button("Stop", role: .cancel) { runner.stop() }
            } else {
                Button("Start test") { runner.start(target: target, load: load) }
                    .buttonStyle(.borderedProminent)
                    .disabled((monitor.battery?.stateOfCharge ?? 0) <= target + 5)
            }
        }
    }

    /// What each load level corresponds to in everyday use, and what disturbs the test.
    @ViewBuilder
    private var loadLegend: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow {
                Text("Light load").fontWeight(.semibold)
                Text("No extra load, display on — like web browsing, writing or watching videos.")
            }
            GridRow {
                Text("Medium").fontWeight(.semibold)
                Text("Half of the CPU cores busy — like heavy multitasking or photo editing.")
            }
            GridRow {
                Text("Heavy").fontWeight(.semibold)
                Text("All CPU cores and the GPU busy — like gaming, video export or 3D rendering.")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        Label("For a reliable result, close other apps and keep the display brightness the same during the test. Other apps add load and change the power and the duration; the measured capacity stays valid, but only tests with the same load and brightness can be compared.",
              systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var liveView: some View {
        let live = runner.live
        let last = runner.samples.last
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                Tile(title: "Charge", value: last?.percent.map { Format.percent($0) } ?? "–")
                Tile(title: "Elapsed", value: Format.duration(runner.elapsed))
                Tile(title: "Delivered", value: Format.milliampHours(Int(live.deliveredMAh)))
                Tile(title: "Energy", value: Format.watthours(live.deliveredWh))
                Tile(title: "Power", value: last.map { Format.watts(Double($0.voltage) * Double(-$0.amperage) / 1_000_000, digits: 1) } ?? "–")
                Tile(title: "Voltage", value: last.map { Format.volts(millivolts: $0.voltage) } ?? "–")
                Tile(title: "Temperature", value: last?.temperature.map { Format.temperature($0) } ?? "–")
                Tile(title: "Time to stop level", value: runner.remaining(live).map { Format.duration($0) } ?? "–")
            }
            if runner.samples.filter({ !$0.idle }).count > 2 {
                Chart(runner.samples.filter { !$0.idle }, id: \.time) { s in
                    LineMark(x: .value("Time", s.time / 60), y: .value("Voltage", Double(s.voltage) / 1000))
                        .foregroundStyle(TemperatureColor.cool)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxisLabel(String(localized: "minutes"))
                .chartYAxisLabel("V")
                .frame(height: 160)
            }
        }
    }

    private func saveCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = CapacityRunner.csvFileName()
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try runner.csv().write(to: url) } catch { NSAlert(error: error).runModal() }
    }
}

@available(macOS 14.0, *)
struct CapacityResultView: View {
    let result: CapacityResult

    var body: some View {
        let findings = result.findings
        VStack(alignment: .leading, spacing: 8) {
            if findings.isEmpty {
                Label("Delivered charge matches the battery gauge.", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.cool)
            }
            ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                Label(CapacityText.finding(f), systemImage: f == .tooShort ? "info.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(f == .tooShort ? AnyShapeStyle(.secondary) : AnyShapeStyle(TemperatureColor.hot))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(CapacityText.rows(result).enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: row.0).foregroundStyle(.secondary)
                        Text(verbatim: row.1)
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.cardFill, in: RoundedRectangle(cornerRadius: Design.cardRadius))
    }
}
