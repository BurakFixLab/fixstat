import AppKit
import Charts
import MacSensors
import SwiftUI
import UniformTypeIdentifiers
import FixStatCore

/// Runs the battery capacity (discharge) test.
@available(macOS 14.0, *)
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
    @ObservationIgnored private var journal: FileHandle?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    /// Samples are also appended to this file, so a run down to 0 % survives the Mac
    /// turning itself off; the result is recovered at the next launch.
    private var journalURL: URL { Monitor.dataDirectory.appendingPathComponent("capacity-run.jsonl") }

    struct JournalHeader: Codable {
        var startedAt: Date
        var fullChargeCapacity: Int?
        var designCapacity: Int?
        var target: Double
    }

    static let interval = 5.0
    static let settleTime = 30.0
    static let temperatureLimit = 50.0

    init(monitor: Monitor) {
        self.monitor = monitor
        if !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--export") {
            recoverJournal()
        }
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
        // macOS forces a sleep when the battery is almost empty (or the lid was closed):
        // end the test with what was measured before.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        tick()
    }

    private func didWake() {
        guard state == .settling || state == .running else { return }
        finish(Self.sleepReason(samples))
    }

    /// A run that ended because the Mac went to sleep: at low charge that is macOS'
    /// low-battery sleep, otherwise (lid closed, …) just the end of the run.
    static func sleepReason(_ samples: [CapacitySample]) -> CapacityResult.StopReason {
        (samples.last?.percent ?? 100) <= 10 ? .batteryEmpty : .stopped
    }

    /// A run that ended because the Mac turned off: above a few percent the battery
    /// could not deliver what the gauge still showed.
    static func shutdownReason(_ samples: [CapacitySample]) -> CapacityResult.StopReason {
        (samples.last?.percent ?? 100) <= 5 ? .batteryEmpty : .unexpectedShutdown
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
            openJournal()
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
        let sample = CapacitySample(time: clock.timeIntervalSince(startedAt), voltage: voltage, amperage: amperage,
                                    percent: b.stateOfCharge, remaining: b.rawCurrentCapacity,
                                    cells: b.cellVoltages, temperature: b.temperature, idle: idle)
        samples.append(sample)
        if let line = try? JSONEncoder().encode(sample) {
            journal?.write(line + Data("\n".utf8))
        }
    }

    private func openJournal() {
        try? FileManager.default.createDirectory(at: Monitor.dataDirectory, withIntermediateDirectories: true)
        let header = JournalHeader(startedAt: startedAt, fullChargeCapacity: fullChargeCapacity,
                                   designCapacity: designCapacity, target: target)
        guard let line = try? JSONEncoder().encode(header),
              FileManager.default.createFile(atPath: journalURL.path, contents: line + Data("\n".utf8)) else { return }
        journal = try? FileHandle(forWritingTo: journalURL)
        _ = try? journal?.seekToEnd()
    }

    /// A journal left behind means the Mac turned off during the test.
    private func recoverJournal() {
        guard let text = try? String(contentsOf: journalURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: journalURL)
        let lines = text.split(separator: "\n").map { Data($0.utf8) }
        let decoder = JSONDecoder()
        guard let first = lines.first, let header = try? decoder.decode(JournalHeader.self, from: first) else { return }
        let recovered = lines.dropFirst().compactMap { try? decoder.decode(CapacitySample.self, from: $0) }
        guard recovered.contains(where: { !$0.idle }) else { return }
        samples = recovered
        startedAt = header.startedAt
        target = header.target
        fullChargeCapacity = header.fullChargeCapacity
        designCapacity = header.designCapacity
        let result = CapacityResult.compute(samples: recovered, startedAt: header.startedAt,
                                            stopReason: Self.shutdownReason(recovered),
                                            fullChargeCapacity: header.fullChargeCapacity,
                                            designCapacity: header.designCapacity)
        self.result = result
        monitor.lastCapacityResult = result
        state = .finished
        if result.stopReason == .unexpectedShutdown, let percent = result.endPercent {
            AlertManager.postOnce(.unexpectedShutdown, body: String(localized: "Capacity test: the Mac turned off unexpectedly at \(Format.percent(percent)). The battery may be faulty."))
        }
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
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        try? journal?.close()
        journal = nil
        try? FileManager.default.removeItem(at: journalURL)
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

@available(macOS 14.0, *)
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
                loadLegend
                if target == 0 && !busy {
                    Label("At 0 % macOS puts the Mac to sleep or turns it off by itself. The measurements are saved while the test runs; if the Mac turns off — also early, as a weak battery does — the result appears here the next time FixStat opens. Full discharges wear the battery, so use them sparingly.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
