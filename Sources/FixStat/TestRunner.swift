import Foundation
import MacSensors
import Observation
import FixStatCore

/// Runs the post-repair stress test: applies CPU / GPU load for a fixed time and
/// samples temperatures and battery values every second.
@available(macOS 14.0, *)
@MainActor
@Observable
final class TestRunner {
    enum State: Equatable {
        case idle, running, finished
    }

    private(set) var state = State.idle
    private(set) var samples: [StressSample] = []
    private(set) var result: StressTestResult?
    private(set) var startedAt = Date()
    private(set) var duration: TimeInterval = 300

    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored private var flag: StopFlag?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loads: [String] = []
    /// Keeps App Nap and idle sleep away while the test runs; a menu bar app is
    /// otherwise throttled and the GPU load stalls.
    @ObservationIgnored private var activity: NSObjectProtocol?

    init(monitor: Monitor) {
        self.monitor = monitor
    }

    var elapsed: TimeInterval { samples.last?.time ?? 0 }

    func start(duration: TimeInterval, cpu: Bool, gpu: Bool) {
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
        if gpu { LoadGenerator.gpu(flag: flag) }
        monitor.testRunning = true
        state = .running
        takeSample()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard state == .running else { return }
        finish()
    }

    private func tick() {
        takeSample()
        if elapsed >= duration { finish() }
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
    }
}
