import FixStatCore
import MacSensors
import SwiftUI

/// Broken-sensor check: watches every sensor for a minute, then lists suspicious sensors
/// and the symptoms a missing sensor causes.
@available(macOS 14.0, *)
struct SensorCheckView: View {
    @Environment(Monitor.self) private var monitor
    @State private var checker: SensorChecker?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let checker {
                if checker.running {
                    HStack(spacing: 8) {
                        ProgressView(value: checker.fraction).frame(maxWidth: 240)
                        Text("Watching the sensors… \(Format.duration(max(checker.duration - checker.elapsed, 0).rounded(.up)))")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop", role: .cancel) { checker.stop() }
                    }
                } else {
                    Button(monitor.lastSensorCheck == nil ? "Check sensors" : "Check again") { checker.start() }
                }
            }
            if let result = monitor.lastSensorCheck {
                SensorCheckResultView(result: result)
            }
        }
        .font(.callout)
        .onAppear {
            let checker = checker ?? SensorChecker(monitor: monitor)
            self.checker = checker
            // Passive and harmless: start right away the first time.
            if monitor.lastSensorCheck == nil, !checker.running { checker.start() }
        }
        .onDisappear { checker?.stop() }
    }
}

@available(macOS 14.0, *)
struct SensorCheckResultView: View {
    let result: SensorCheckResult

    var body: some View {
        VStack(alignment: .leading, spacing: Design.cardSpacing) {
            FindingRow(text: SensorCheckText.verdict(result), problem: !result.passed)
                .font(.headline)
            if !result.known.isEmpty {
                Card {
                    CardHeader("Suspicious sensors", systemImage: "thermometer.medium.slash")
                    ForEach(Array(result.known.enumerated()), id: \.offset) { _, fault in
                        FindingRow(text: SensorCheckText.fault(fault, name: result.names[fault.uid]))
                    }
                }
            }
            let symptoms = SensorCheckText.symptoms(result)
            if !symptoms.isEmpty {
                Card {
                    CardHeader("What the Mac does", systemImage: "fan")
                    ForEach(Array(symptoms.enumerated()), id: \.offset) { _, line in
                        FindingRow(text: line)
                    }
                }
            }
            if !result.unclear.isEmpty {
                Card {
                    CardHeader("Unclear", systemImage: "questionmark.circle")
                    Text(verbatim: SensorCheckText.unclearNote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(result.unclear.enumerated()), id: \.offset) { _, fault in
                        Text(verbatim: "• " + SensorCheckText.fault(fault, name: result.names[fault.uid]))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// SwiftUI view of the core `SensorCheckRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class SensorChecker {
    private(set) var running = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var fraction = 0.0
    var duration: TimeInterval { runner.duration }

    @ObservationIgnored private let runner: SensorCheckRunner

    init(monitor: Monitor) {
        runner = SensorCheckRunner(monitor: monitor.core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let wasRunning = self.running
                self.sync()
                // The core stored the result; let the views observe it.
                if wasRunning, !self.running { monitor.lastSensorCheck = monitor.core.lastSensorCheck }
            }
        }
    }

    func start() { runner.start() }
    func stop() { runner.stop() }

    private func sync() {
        let nowRunning = runner.state == .running
        if nowRunning != running { running = nowRunning }
        elapsed = runner.elapsed
        fraction = runner.fraction
    }
}
