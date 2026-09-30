import AppKit
import MacSensors

/// Runs the battery capacity (discharge) test. Main thread; `onChange` after every step.
public final class CapacityRunner {
    public enum State: Equatable { case idle, waitingForUnplug, settling, running, finished }
    public enum Load: Int, CaseIterable { case light, medium, heavy }

    public private(set) var state = State.idle
    public private(set) var samples: [CapacitySample] = []
    public private(set) var result: CapacityResult?
    public private(set) var target = 20.0
    public private(set) var load = Load.medium
    public var onChange: (() -> Void)?
    /// Brings the test window to the front when the test ends.
    public var bringToFront: (() -> Void)?

    private let monitor: MonitorCore
    private var timer: Timer?
    private var flag: StopFlag?
    private var activity: NSObjectProtocol?
    private var startedAt = Date()
    private var clock = Date()
    private var fullChargeCapacity: Int?
    private var designCapacity: Int?
    private var journal: FileHandle?
    private var wakeObserver: NSObjectProtocol?

    /// Samples are also appended to this file, so a run down to 0 % survives the Mac
    /// turning itself off; the result is recovered at the next launch.
    private var journalURL: URL { MonitorCore.dataDirectory.appendingPathComponent("capacity-run.jsonl") }

    struct JournalHeader: Codable {
        var startedAt: Date
        var fullChargeCapacity: Int?
        var designCapacity: Int?
        var target: Double
    }

    public static let interval = 5.0
    public static let settleTime = 30.0
    public static let temperatureLimit = 50.0

    public init(monitor: MonitorCore) {
        self.monitor = monitor
        if !CommandLine.arguments.contains("--snapshot") && !CommandLine.arguments.contains("--export") {
            recoverJournal()
        }
    }

    public var busy: Bool { [.waitingForUnplug, .settling, .running].contains(state) }

    public var elapsed: TimeInterval { samples.last(where: { !$0.idle }).map { $0.time - (firstLoaded?.time ?? 0) } ?? 0 }
    private var firstLoaded: CapacitySample? { samples.first { !$0.idle } }

    /// Charge delivered so far (same integration as the final result).
    public var live: CapacityResult {
        CapacityResult.compute(samples: samples, startedAt: startedAt, stopReason: .stopped,
                               fullChargeCapacity: fullChargeCapacity, designCapacity: designCapacity)
    }

    /// Time until the stop level at the average rate so far.
    public func remaining(_ live: CapacityResult) -> TimeInterval? {
        guard let p0 = live.startPercent, let p1 = live.endPercent, p0 - p1 >= 1, live.duration > 60 else { return nil }
        let rate = (p0 - p1) / live.duration
        return max(0, (p1 - target) / rate)
    }

    public func start(target: Double, load: Load) {
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
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // macOS forces a sleep when the battery is almost empty (or the lid was closed):
        // end the test with what was measured before.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.didWake()
        }
        tick()
        onChange?()
    }

    private func didWake() {
        guard state == .settling || state == .running else { return }
        finish(Self.sleepReason(samples))
    }

    /// A run that ended because the Mac went to sleep: at low charge that is macOS'
    /// low-battery sleep, otherwise (lid closed, …) just the end of the run.
    public static func sleepReason(_ samples: [CapacitySample]) -> CapacityResult.StopReason {
        (samples.last?.percent ?? 100) <= 10 ? .batteryEmpty : .stopped
    }

    /// A run that ended because the Mac turned off: above a few percent the battery
    /// could not deliver what the gauge still showed.
    public static func shutdownReason(_ samples: [CapacitySample]) -> CapacityResult.StopReason {
        (samples.last?.percent ?? 100) <= 5 ? .batteryEmpty : .unexpectedShutdown
    }

    public func stop() {
        switch state {
        case .waitingForUnplug:
            cleanUp()
            state = .idle
            onChange?()
        case .settling, .running:
            finish(.stopped)
        default:
            break
        }
    }

    private func tick() {
        guard let b = BatteryReader.read() else { return }
        let before = (state, samples.count)
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
            if let p = b.stateOfCharge, p <= target { finish(.targetReached); return }
        default:
            break
        }
        if before.0 != state || before.1 != samples.count { onChange?() }
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
        try? FileManager.default.createDirectory(at: MonitorCore.dataDirectory, withIntermediateDirectories: true)
        let header = JournalHeader(startedAt: startedAt, fullChargeCapacity: fullChargeCapacity,
                                   designCapacity: designCapacity, target: target)
        guard let line = try? JSONEncoder().encode(header),
              FileManager.default.createFile(atPath: journalURL.path, contents: line + Data("\n".utf8)) else { return }
        journal = try? FileHandle(forWritingTo: journalURL)
        // The pre-10.15 method: macOS 10.13 has no seekToEnd().
        journal?.seekToEndOfFile()
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
            AlertManager.postOnce(.unexpectedShutdown,
                                  body: L("Capacity test: the Mac turned off unexpectedly at %@. The battery may be faulty.",
                                          Format.percent(percent)))
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
            _ = LoadGenerator.gpu(flag: flag)
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
        onChange?()
        bringToFront?()
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
        journal?.closeFile()
        journal = nil
        try? FileManager.default.removeItem(at: journalURL)
    }

    public func csv() -> Data {
        var lines = ["seconds,phase,voltage_mV,amperage_mA,percent,remaining_mAh,temperature_C,cells_mV"]
        for s in samples {
            lines.append([String(format: "%.0f", s.time), s.idle ? "idle" : "load", "\(s.voltage)", "\(s.amperage)",
                          s.percent.map { String(format: "%.1f", $0) } ?? "", s.remaining.map(String.init) ?? "",
                          s.temperature.map { String(format: "%.1f", $0) } ?? "",
                          (s.cells ?? []).map(String.init).joined(separator: " ")].joined(separator: ","))
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    public static func csvFileName(now: Date = Date()) -> String {
        "FixStat-capacity-\(Format.isoDay(now)).csv"
    }
}
