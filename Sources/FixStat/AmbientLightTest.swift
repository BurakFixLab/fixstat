import MacSensors
import SwiftUI
import FixStatCore

/// Guided ambient light sensor test: normal light → covered → flashlight, with the camera
/// as a second opinion on whether the flashlight really reached the sensor.
@available(macOS 14.0, *)
struct AmbientLightTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var tester = LightTester()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if tester.available == false {
                Label("No ambient light sensor found. On MacBooks this points to the camera board or the display cable.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(verbatim: tester.reading.map(LightText.value) ?? "–")
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                    if let auto = AmbientLightSensor.automaticBrightnessEnabled {
                        Text(auto ? "Automatic brightness: on" : "Automatic brightness: off")
                            .foregroundStyle(.secondary)
                    }
                }
                steps
                if let prompt = tester.prompt {
                    Label(prompt, systemImage: "hand.point.right")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if tester.phase == .confirm {
                    HStack {
                        Button("Yes, the light was on the sensor") { tester.confirmLight(true) }
                        Button("Try again") { tester.confirmLight(false) }
                    }
                }
                HStack {
                    Button(tester.phase == .idle ? "Start test" : "Restart") { tester.start() }
                        .buttonStyle(.borderedProminent)
                    if tester.cameraPermissionDenied {
                        Text("Without camera access the flashlight is confirmed by hand.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let result = tester.result {
                    resultView(result)
                }
            }
        }
        .onAppear { tester.prepare() }
        .onDisappear { tester.stop() }
        .onChange(of: tester.available) { _, available in
            if available == false {
                monitor.recordCheck(.ambientLight, detail: LightText.finding(.notFound), failed: true)
            }
        }
        .onChange(of: tester.resultID) { _, _ in
            guard let result = tester.result else { return }
            monitor.recordCheck(.ambientLight, detail: tester.detail ?? "", passed: result.verdict == .passed,
                                failed: result.verdict == .failed)
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 6) {
            stepRow(1, "Normal light", done: tester.phase.rawValue > LightTester.Phase.room.rawValue, active: tester.phase == .room,
                    value: tester.roomMean)
            stepRow(2, "Cover the sensor", done: tester.phase.rawValue > LightTester.Phase.covered.rawValue,
                    active: tester.phase == .covered, value: tester.coveredMin)
            stepRow(3, "Flashlight", done: tester.phase == .done, active: tester.phase == .bright || tester.phase == .confirm,
                    value: tester.brightMax)
        }
    }

    private func stepRow(_ number: Int, _ title: LocalizedStringKey, done: Bool, active: Bool,
                         value: LightReadingValue?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : active ? "circle.dotted" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(TemperatureColor.cool) : AnyShapeStyle(.secondary))
            Text("\(number). ") + Text(title)
            Spacer()
            if let value { Text(verbatim: LightText.value(value)).foregroundStyle(.secondary).monospacedDigit() }
        }
        .font(.callout)
        .frame(maxWidth: 420)
    }

    private func resultView(_ result: (verdict: LightCheck.Verdict, findings: [LightCheck.Finding])) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.verdict == .passed {
                Label("The ambient light sensor responds correctly.", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(TemperatureColor.cool)
            }
            ForEach(Array(result.findings.enumerated()), id: \.offset) { _, finding in
                Label(LightText.finding(finding), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(finding == .cameraDidNotSeeLight ? AnyShapeStyle(.secondary) : AnyShapeStyle(TemperatureColor.hot))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// SwiftUI view of the core `LightTestRunner`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class LightTester {
    typealias Phase = LightTestRunner.Phase

    private(set) var available: Bool?
    private(set) var reading: LightReadingValue?
    private(set) var phase = Phase.idle
    private(set) var prompt: String?
    private(set) var result: (verdict: LightCheck.Verdict, findings: [LightCheck.Finding])?
    private(set) var resultID = 0
    private(set) var cameraPermissionDenied = false

    @ObservationIgnored private let runner = LightTestRunner()

    init() {
        runner.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    var roomMean: LightReadingValue? { runner.roomMean }
    var coveredMin: LightReadingValue? { runner.coveredMin }
    var brightMax: LightReadingValue? { runner.brightMax }
    var detail: String? { runner.detail }

    func prepare() { runner.prepare() }
    func stop() { runner.stop() }
    func start() { runner.start() }
    func confirmLight(_ wasOnSensor: Bool) { runner.confirmLight(wasOnSensor) }

    private func sync() {
        if runner.available != available { available = runner.available }
        if runner.reading != reading { reading = runner.reading }
        if runner.phase != phase { phase = runner.phase }
        if runner.prompt != prompt { prompt = runner.prompt }
        if runner.resultID != resultID {
            result = runner.result
            resultID = runner.resultID
        }
        if runner.cameraPermissionDenied != cameraPermissionDenied { cameraPermissionDenied = runner.cameraPermissionDenied }
    }
}
