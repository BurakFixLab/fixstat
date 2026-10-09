import Foundation
import MacSensors

/// The hardware check's fan test: shows the fans live, then puts load on the CPU and GPU
/// and watches every fan follow the speed the system asks for (`FanCheck`), and finally
/// the spin-down. FixStat never writes fan speeds. Main thread; `onChange` every second.
public final class FanTestRunner {
    public enum State: Equatable { case idle, loading, coolingDown, finished }

    public private(set) var state = State.idle
    public private(set) var fans: [FanReading] = []
    public private(set) var cpuTemperature: Double?
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var check = FanCheck()
    public var onChange: (() -> Void)?

    /// 90 s of load, 30 s of spin-down (shorter for snapshots).
    public var loadSeconds: TimeInterval = 90
    public var coolSeconds: TimeInterval = 30

    private let monitor: MonitorCore
    private let smc = try? SMC()
    private var timer: Timer?
    private var flag: StopFlag?
    private var activity: NSObjectProtocol?

    /// `-FixStatSimulateFans N`: N made-up fans that follow the load (for checking the UI
    /// on a fanless Mac).
    static var simulatedFans: Int { UserDefaults.standard.integer(forKey: "FixStatSimulateFans") }

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public var isRunning: Bool { state == .loading || state == .coolingDown }

    /// Starts showing the fans (call when the pane appears).
    public func prepare() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Stops everything (pane disappears).
    public func stop() {
        timer?.invalidate()
        timer = nil
        if isRunning { endLoad(); state = .idle }
    }

    /// Ends a running test without a result.
    public func cancel() {
        guard isRunning else { return }
        endLoad()
        state = .idle
        onChange?()
    }

    /// Text for the current step: "Load · 0:42 of 1:30", "Slowing down · 0:12".
    public var progress: String? {
        switch state {
        case .loading:
            return L("Load on CPU and GPU · %@ of %@", Format.duration(elapsed), Format.duration(loadSeconds))
        case .coolingDown:
            return L("Load stopped, the fans slow down · %@", Format.duration(elapsed - loadSeconds))
        default:
            return nil
        }
    }

    public func start() {
        guard !isRunning else { return }
        check = FanCheck()
        elapsed = 0
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: "Fan test")
        let flag = StopFlag()
        self.flag = flag
        let cores = ProcessInfo.processInfo.activeProcessorCount
        LoadGenerator.cpu(threads: max(1, cores - 1), flag: flag)
        _ = LoadGenerator.gpu(flag: flag)
        monitor.testRunning = true
        state = .loading
        prepare()
        onChange?()
    }

    private func endLoad() {
        flag?.stop()
        flag = nil
        monitor.testRunning = false
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func tick() {
        fans = read()
        if isRunning {
            monitor.refresh()
            cpuTemperature = monitor.cpuTemperature
            check.add(fans)
            elapsed += 1
            if state == .loading, elapsed >= loadSeconds {
                flag?.stop()
                state = .coolingDown
            } else if state == .coolingDown, elapsed >= loadSeconds + coolSeconds {
                endLoad()
                state = .finished
                let verdict = check.verdict
                switch verdict {
                case .passed: monitor.recordCheck(.fans, detail: FanText.detail(check), passed: true)
                case .stalled, .belowTarget, .aboveTarget:
                    monitor.recordCheck(.fans, detail: FanText.verdict(verdict), failed: true)
                case .notAsked: monitor.recordCheck(.fans, detail: FanText.verdict(verdict) + " " + FanText.detail(check))
                }
            }
        } else {
            cpuTemperature = monitor.cpuTemperature
        }
        onChange?()
    }

    private var simulatedTarget = 1200.0

    private func read() -> [FanReading] {
        let count = Self.simulatedFans
        guard count > 0 else { return smc?.fans() ?? [] }
        // Made up: the target climbs under load and falls afterwards; the fans lag behind.
        simulatedTarget = state == .loading ? min(5000, simulatedTarget + 150) : max(1200, simulatedTarget - 150)
        return (0..<count).map { i in
            let lag = fans.first { $0.index == i }?.actual ?? 1200
            return FanReading(index: i, actual: lag + (simulatedTarget - lag) * 0.6, minimum: 1200, maximum: 6000,
                              target: simulatedTarget)
        }
    }
}

/// Texts of the fan test (both interfaces and the report).
public enum FanText {
    public static func detail(_ check: FanCheck) -> String {
        check.fans.map { fan in
            L("Fan %lld: %@ → %@ (max %@)", fan.index + 1, Format.rpm(fan.idle ?? 0), Format.rpm(fan.peak),
              fan.maximum.map(Format.rpm) ?? "–")
        }.joined(separator: " · ")
    }

    public static func verdict(_ verdict: FanCheck.Verdict) -> String {
        switch verdict {
        case .passed:
            return L("Every fan followed the speed the system asked for.")
        case let .stalled(fan, target):
            return L("Fan %lld does not turn although the system asks for %@: check the connector and the fan.",
                     fan + 1, Format.rpm(target))
        case let .belowTarget(fan, actual, target):
            return L("Fan %lld stays well below its target (%@ instead of %@): worn bearing, dirt or a weak fan.",
                     fan + 1, Format.rpm(actual), Format.rpm(target))
        case let .aboveTarget(fan, actual, target):
            return L("Fan %1$lld runs at %2$@ although the system asks for only %3$@: the SMC does not control it. Before the sensors, check the fan itself (try a known-good fan) and its drive circuit (PWM line, fan connector, fan power); this is common after liquid damage.",
                     fan + 1, Format.rpm(actual), Format.rpm(target))
        case .notAsked:
            return L("The fans were not asked to speed up: the Mac stayed cool enough. Judge them by ear, or test again when the Mac is warm.")
        }
    }

    /// One fan's live line: "2 450 rpm · target 2 500 rpm · 1 200–6 000 rpm".
    public static func live(_ fan: FanReading) -> String {
        let runsAway = fan.actual.flatMap { actual in fan.target.map { FanCheck.runsAway(actual: actual, target: $0) } } ?? false
        return [fan.target.map { L("target %@", Format.rpm($0)) }, runsAway ? L("far above the target") : nil,
         fan.minimum.flatMap { min in fan.maximum.map { L("range %@–%@", Format.number(min), Format.rpm($0)) } }]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
