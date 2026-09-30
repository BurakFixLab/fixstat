import Foundation
import MacSensors

/// Runs the post-repair stress test: applies CPU / GPU load for a fixed time and samples
/// temperatures and battery values every second. Main thread; `onChange` after every step.
public final class StressTestRunner {
    public enum State: Equatable {
        case idle, running, finished
    }

    public private(set) var state = State.idle
    public private(set) var samples: [StressSample] = []
    public private(set) var result: StressTestResult?
    public private(set) var startedAt = Date()
    public private(set) var duration: TimeInterval = 300
    /// Called on the main thread whenever the state, samples or result changed.
    public var onChange: (() -> Void)?

    private let monitor: MonitorCore
    private var flag: StopFlag?
    private var timer: Timer?
    private var loads: [String] = []
    /// Keeps App Nap and idle sleep away while the test runs; a menu bar app is
    /// otherwise throttled and the GPU load stalls.
    private var activity: NSObjectProtocol?

    public init(monitor: MonitorCore) {
        self.monitor = monitor
    }

    public var elapsed: TimeInterval { samples.last?.time ?? 0 }

    public func start(duration: TimeInterval, cpu: Bool, gpu: Bool) {
        guard state != .running, cpu || gpu else { return }
        self.duration = duration
        samples = []
        result = nil
        startedAt = Date()
        loads = (cpu ? ["cpu"] : []) + (gpu ? ["gpu"] : [])

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Post-repair stress test"
        )
        let flag = StopFlag()
        self.flag = flag
        // With the GPU load running, leave one core for feeding the GPU, sampling and the UI.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if cpu { LoadGenerator.cpu(threads: gpu ? max(1, cores - 1) : cores, flag: flag) }
        if gpu { _ = LoadGenerator.gpu(flag: flag) }
        monitor.testRunning = true
        state = .running
        takeSample()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        onChange?()
    }

    public func stop() {
        guard state == .running else { return }
        finish()
    }

    private func tick() {
        takeSample()
        if elapsed >= duration {
            finish()
        } else {
            onChange?()
        }
    }

    private func takeSample() {
        monitor.refresh()
        let battery = monitor.battery
        func hottest(_ group: SensorMap.Group) -> Double? {
            monitor.sensors.filter { $0.group == group }.compactMap(monitor.value(of:)).max()
        }
        let sample = StressSample(
            time: Date().timeIntervalSince(startedAt),
            cpu: hottest(.cpu), gpu: hottest(.gpu), ssd: hottest(.ssd), battery: battery?.temperature,
            cellVoltages: battery?.cellVoltages, amperage: battery?.amperage,
            stateOfCharge: battery?.stateOfCharge, externalConnected: battery?.externalConnected
        )
        samples = samples + [sample]
    }

    private func finish() {
        flag?.stop()
        flag = nil
        timer?.invalidate()
        timer = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        monitor.testRunning = false
        let defaults = UserDefaults.standard
        let hot = defaults.double(forKey: Pref.hotThreshold)
        let imbalance = defaults.integer(forKey: Pref.cellImbalanceThreshold)
        let result = StressTestResult.analyze(
            samples: samples, startedAt: startedAt, plannedDuration: duration, loads: loads,
            hotThreshold: hot > 0 ? hot : Pref.defaultHot,
            imbalanceThreshold: imbalance > 0 ? imbalance : Pref.defaultCellImbalance
        )
        self.result = result
        monitor.lastTestResult = result
        state = .finished
        onChange?()
    }
}
