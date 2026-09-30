import Foundation
import MacSensors
import Observation
import FixStatCore

/// SwiftUI view of the core `StressTestRunner` (post-repair stress test).
@available(macOS 14.0, *)
@MainActor
@Observable
final class TestRunner {
    typealias State = StressTestRunner.State

    private(set) var state = State.idle
    private(set) var samples: [StressSample] = []
    private(set) var result: StressTestResult?
    private(set) var duration: TimeInterval = 300

    @ObservationIgnored private let runner: StressTestRunner
    @ObservationIgnored private let monitor: Monitor

    init(monitor: Monitor) {
        self.monitor = monitor
        runner = StressTestRunner(monitor: monitor.core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    var elapsed: TimeInterval { samples.last?.time ?? 0 }

    func start(duration: TimeInterval, cpu: Bool, gpu: Bool) {
        runner.start(duration: duration, cpu: cpu, gpu: gpu)
    }

    func stop() {
        runner.stop()
    }

    private func sync() {
        if runner.state != state { state = runner.state }
        samples = runner.samples
        if runner.result != result {
            result = runner.result
            // Reports read it from the core; tell observers of the Monitor too.
            monitor.lastTestResult = runner.result
        }
        duration = runner.duration
    }
}
