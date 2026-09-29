import AppKit
import Charts
import MacSensors
import SwiftUI
import UniformTypeIdentifiers

/// Runs the battery capacity (discharge) test.
@MainActor
@Observable
final class CapacityTestRunner {
    enum State: Equatable { case idle, waitingForUnplug, settling, running, finished }
    enum Load: Int, CaseIterable { case light, medium, heavy }

    private(set) var state = State.idle
    private(set) var samples: [CapacitySample] = []
    private(set) var result: CapacityResult?
    private(set) var target = 20.0
    private(set) var load = Load.medium

    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var flag: StopFlag?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var clock = Date()
    @ObservationIgnored private var fullChargeCapacity: Int?
    @ObservationIgnored private var designCapacity: Int?

    static let interval = 5.0
    static let settleTime = 30.0
    static let temperatureLimit = 50.0

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    var elapsed: TimeInterval { samples.last(where: { !$0.idle }).map { $0.time - (firstLoaded?.time ?? 0) } ?? 0 }
    private var firstLoaded: CapacitySample? { samples.first { !$0.idle } }

    /// Charge delivered so far (same integration as the final result).
    var live: CapacityResult {
        CapacityResult.compute(samples: samples, startedAt: startedAt, stopReason: .stopped,
                               fullChargeCapacity: fullChargeCapacity, designCapacity: designCapacity)
    }

    func start(target: Double, load: Load) {
        guard state == .idle || state == .finished else { return }
        self.target = target
        self.load = load
        samples = []
        result = nil
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Battery capacity test")
        state = .waitingForUnplug
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        switch state {
        case .waitingForUnplug: cleanUp(); state = .idle
        case .settling, .running: finish(.stopped)
        default: break
        }
    }

    private func tick() {
        guard let b = BatteryReader.read() else { return }
        switch state {
        case .waitingForUnplug:
            guard b.externalConnected == false else { return }
            startedAt = Date()
            clock = startedAt
            fullChargeCapacity = b.rawMaxCapacity
            designCapacity = b.designCapacity
            state = .settling
            record(b, idle: true)
        case .settling:
            guard Date().timeIntervalSince(clock) >= Self.interval else { return }
            if b.externalConnected == true { finish(.adapterConnected); return }
            record(b, idle: true)
            if Date().timeIntervalSince(startedAt) >= Self.settleTime { startLoad() }
        case .running:
            if b.externalConnected == true { finish(.adapterConnected); return }
            guard Date().timeIntervalSince(clock) >= Self.interval else { return }
            record(b, idle: false)
            if let t = b.temperature, t >= Self.temperatureLimit { finish(.tooHot); return }
            if let p = b.stateOfCharge, p <= target { finish(.targetReached) }
        default:
            break
        }
    }

    private func record(_ b: BatteryInfo, idle: Bool) {
        clock = Date()
        guard let voltage = b.voltage, let amperage = b.amperage else { return }
        samples.append(CapacitySample(time: clock.timeIntervalSince(startedAt), voltage: voltage, amperage: amperage,
                                      percent: b.stateOfCharge, remaining: b.rawCurrentCapacity,
                                      cells: b.cellVoltages, temperature: b.temperature, idle: idle))
    }

    private func startLoad() {
        let flag = StopFlag()
        self.flag = flag
        let cores = ProcessInfo.processInfo.activeProcessorCount
        switch load {
        case .light: break
        case .medium: LoadGenerator.cpu(threads: max(1, cores / 2), flag: flag)
        case .heavy:
            LoadGenerator.cpu(threads: max(1, cores - 1), flag: flag)
            LoadGenerator.gpu(flag: flag)
        }
        state = .running
    }

    private func finish(_ reason: CapacityResult.StopReason) {
        let result = CapacityResult.compute(samples: samples, startedAt: startedAt, stopReason: reason,
                                            fullChargeCapacity: fullChargeCapacity, designCapacity: designCapacity)
        self.result = result
        monitor.lastCapacityResult = result
        cleanUp()
        state = .finished
        NSApp.activate()
        NSApp.windows.first { $0.identifier?.rawValue.contains(CapacityTestView.windowID) == true }?
            .makeKeyAndOrderFront(nil)
    }

    private func cleanUp() {
        flag?.stop()
        flag = nil
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    func csv() -> Data {
        var lines = ["seconds,phase,voltage_mV,amperage_mA,percent,remaining_mAh,temperature_C,cells_mV"]
        for s in samples {
            lines.append([String(format: "%.0f", s.time), s.idle ? "idle" : "load", "\(s.voltage)", "\(s.amperage)",
                          s.percent.map { String(format: "%.1f", $0) } ?? "", s.remaining.map(String.init) ?? "",
                          s.temperature.map { String(format: "%.1f", $0) } ?? "",
                          (s.cells ?? []).map(String.init).joined(separator: " ")].joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

struct CapacityTestView: View {
    static let windowID = "capacity"

    @Environment(CapacityTestRunner.self) private var runner
    @Environment(Monitor.self) private var monitor
    @State private var target = 20.0
    @State private var load = CapacityTestRunner.Load.medium

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Discharges the battery under a steady load from the current charge down to the chosen level and compares the charge actually delivered with what the battery gauge reports. Start fully charged; the test takes one to several hours. The Mac stays awake and the display stays on.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                controls
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
                ForEach([50.0, 20.0, 10.0], id: \.self) { Text(Format.percent($0)).tag($0) }
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
                Tile(title: "Time to stop level", value: remaining(live).map { Format.duration($0) } ?? "–")
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

    /// Time until the stop level at the average rate so far.
    private func remaining(_ live: CapacityResult) -> TimeInterval? {
        guard let p0 = live.startPercent, let p1 = live.endPercent, p0 - p1 >= 1, live.duration > 60 else { return nil }
        let rate = (p0 - p1) / live.duration
        return max(0, (p1 - runner.target) / rate)
    }

    private func saveCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "FixStat-capacity-\(Date().formatted(.iso8601.year().month().day())).csv"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try runner.csv().write(to: url) } catch { NSAlert(error: error).runModal() }
    }
}

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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

enum CapacityText {
    static func finding(_ f: CapacityResult.Finding) -> String {
        switch f {
        case .tooShort:
            String(localized: "The charge fell by less than \(Format.percent(CapacityResult.minimumPercentDrop)); the capacity figures are only rough.")
        case .capacityBelowGauge(let ratio):
            String(localized: "The battery delivered only \(Format.percent(ratio * 100)) of the capacity its gauge reports. The gauge overstates the battery (common with reset or non-genuine gauges).")
        case .gaugeMiscount(let ratio):
            String(localized: "The gauge's remaining capacity changed differently from the charge delivered (\(Format.percent(ratio * 100))). The gauge counts incorrectly or needs calibration.")
        case .weakCell(let cell, let spread):
            String(localized: "Cell \(cell) sags under load: cell voltages differ by up to \(Format.millivolts(spread)).")
        }
    }

    static func stopReason(_ r: CapacityResult.StopReason) -> String {
        switch r {
        case .targetReached: String(localized: "Stop level reached")
        case .stopped: String(localized: "Stopped")
        case .adapterConnected: String(localized: "Power adapter connected")
        case .tooHot: String(localized: "Battery too hot")
        }
    }

    static func rows(_ r: CapacityResult) -> [(String, String)] {
        var rows: [(String, String)] = [
            (String(localized: "Result"), stopReason(r.stopReason)),
            (String(localized: "Charge"), [r.startPercent, r.endPercent].map { $0.map { Format.percent($0) } ?? "–" }
                .joined(separator: " → ")),
            (String(localized: "Duration"), Format.duration(r.duration)),
            (String(localized: "Delivered"), Format.milliampHours(Int(r.deliveredMAh)) + " · " + Format.watthours(r.deliveredWh)),
        ]
        if let w = r.averageWatts { rows.append((String(localized: "Average power"), Format.watts(w, digits: 1))) }
        if let e = r.extrapolatedCapacity {
            rows.append((String(localized: "Measured capacity (extrapolated to 100 %)"), Format.milliampHours(Int(e))))
        }
        if let f = r.fullChargeCapacity {
            rows.append((String(localized: "Gauge full charge capacity"), Format.milliampHours(f)
                         + (r.capacityAgreement.map { " · " + String(localized: "measured \(Format.percent($0 * 100))") } ?? "")))
        }
        if let d = r.designCapacity { rows.append((String(localized: "Design capacity"), Format.milliampHours(d))) }
        if let g = r.gaugeAgreement {
            rows.append((String(localized: "Gauge agreement"), Format.percent(g * 100)))
        }
        if let res = r.packResistance {
            rows.append((String(localized: "Pack resistance (load step)"), Format.number(res) + "\u{00A0}mΩ"))
        }
        if let spread = r.maxCellSpread {
            rows.append((String(localized: "Largest cell difference under load"), Format.millivolts(spread)
                         + (r.weakestCell.map { " · " + String(localized: "lowest: cell \($0)") } ?? "")))
        }
        if let v = r.lowestVoltage { rows.append((String(localized: "Lowest voltage"), Format.volts(millivolts: v))) }
        if let t = r.highestTemperature { rows.append((String(localized: "Highest temperature"), Format.temperature(t))) }
        return rows
    }
}
