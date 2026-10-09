import FixStatCore
import MacSensors
import SwiftUI

/// Fan test: live speeds, then load on CPU and GPU and the verdict.
@available(macOS 14.0, *)
struct FanTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var tester: FanTester?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let tester {
                if tester.fans.isEmpty {
                    Text("This Mac has no fans.").foregroundStyle(.secondary)
                } else {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(tester.fans, id: \.index) { fan in
                            GridRow {
                                Text("Fan \(fan.index + 1)").fontWeight(.medium)
                                Text(verbatim: fan.actual.map(Format.rpm) ?? "–").monospacedDigit()
                                Text(verbatim: FanText.live(fan)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let cpu = tester.cpuTemperature {
                        Text("CPU \(Format.temperature(cpu))").foregroundStyle(.secondary)
                    }
                    if let progress = tester.progress {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(verbatim: progress)
                        }
                        Button("Stop") { tester.cancel() }
                    } else {
                        if tester.state == .finished {
                            FanVerdictLabel(check: tester.check)
                        }
                        Button(tester.state == .finished ? "Test again" : "Start fan test") { tester.start() }
                    }
                }
            }
        }
        .font(.callout)
        .onAppear {
            let tester = tester ?? FanTester(core: monitor.core)
            self.tester = tester
            tester.prepare()
        }
        .onDisappear { tester?.stop() }
    }
}

@available(macOS 14.0, *)
private struct FanVerdictLabel: View {
    let check: FanCheck

    var body: some View {
        let verdict = check.verdict
        VStack(alignment: .leading, spacing: 4) {
            switch verdict {
            case .passed:
                Label(FanText.verdict(verdict), systemImage: "checkmark.circle.fill").foregroundStyle(TemperatureColor.cool)
            case .stalled, .belowTarget, .aboveTarget:
                Label(FanText.verdict(verdict), systemImage: "exclamationmark.triangle.fill").foregroundStyle(TemperatureColor.hot)
            case .notAsked:
                Label(FanText.verdict(verdict), systemImage: "info.circle").foregroundStyle(.secondary)
            }
            Text(verbatim: FanText.detail(check)).foregroundStyle(.secondary)
        }
    }
}

/// SwiftUI view of the core `FanTestRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class FanTester {
    private(set) var state = FanTestRunner.State.idle
    private(set) var fans: [FanReading] = []
    private(set) var cpuTemperature: Double?
    private(set) var progress: String?
    private(set) var check = FanCheck()

    @ObservationIgnored private let runner: FanTestRunner

    init(core: MonitorCore) {
        runner = FanTestRunner(monitor: core)
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func prepare() { runner.prepare() }
    func stop() { runner.stop() }
    func start() { runner.start() }
    func cancel() { runner.cancel() }

    private func sync() {
        if runner.state != state { state = runner.state }
        if runner.fans != fans { fans = runner.fans }
        if runner.cpuTemperature != cpuTemperature { cpuTemperature = runner.cpuTemperature }
        if runner.progress != progress { progress = runner.progress }
        if runner.check != check { check = runner.check }
    }
}
