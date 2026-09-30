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
            let detail = result.findings.isEmpty
                ? String(localized: "Normal \(LightText.value(tester.roomMean)) · covered \(LightText.value(tester.coveredMin)) · flashlight \(LightText.value(tester.brightMax))")
                : result.findings.map(LightText.finding).joined(separator: " ")
            monitor.recordCheck(.ambientLight, detail: detail, passed: result.verdict == .passed,
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

@available(macOS 14.0, *)
@MainActor
@Observable
final class LightTester {
    enum Phase: Int { case idle, room, covered, bright, confirm, done }

    private(set) var available: Bool?
    private(set) var reading: LightReadingValue?
    private(set) var phase = Phase.idle
    private(set) var prompt: String?
    private(set) var result: (verdict: LightCheck.Verdict, findings: [LightCheck.Finding])?
    private(set) var resultID = 0
    private(set) var cameraPermissionDenied = false

    @ObservationIgnored private var room: [Double] = []
    @ObservationIgnored private var covered: [Double] = []
    @ObservationIgnored private var bright: [Double] = []
    @ObservationIgnored private var cameraMax: Double?
    @ObservationIgnored private var phaseStart = Date()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let camera = CameraPreview()
    @ObservationIgnored private var cameraStarted = false

    static let roomSeconds = 3.0
    static let coverTimeout = 12.0
    static let brightTimeout = 15.0

    var roomMean: LightReadingValue? { value(LightCheck.mean(room)) }
    var coveredMin: LightReadingValue? { value(covered.min()) }
    var brightMax: LightReadingValue? { value(bright.max()) }

    private func value(_ v: Double?) -> LightReadingValue? {
        guard let v, let source = reading?.source else { return nil }
        return LightReadingValue(value: v, source: source)
    }

    func prepare() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if cameraStarted { camera.stop(); cameraStarted = false }
    }

    func start() {
        room = []
        covered = []
        bright = []
        cameraMax = nil
        result = nil
        begin(.room)
        if !cameraStarted {
            cameraStarted = true
            Task {
                await camera.start()
                cameraPermissionDenied = camera.permission == .denied || camera.permission == .noCamera
            }
        }
    }

    func confirmLight(_ wasOnSensor: Bool) {
        if wasOnSensor {
            finish(cameraBrightness: 1)
        } else {
            bright = []
            begin(.bright)
        }
    }

    private func begin(_ next: Phase) {
        phase = next
        phaseStart = Date()
        switch next {
        case .room: prompt = String(localized: "Keep the sensor uncovered in normal room light…")
        case .covered: prompt = String(localized: "Cover the sensor next to the camera with a finger.")
        case .bright: prompt = String(localized: "Shine a phone flashlight at the sensor next to the camera.")
        case .confirm: prompt = String(localized: "The camera could not confirm the light. Was the flashlight on the sensor?")
        case .idle, .done: prompt = nil
        }
    }

    private func tick() {
        guard let r = AmbientLightSensor.read() else {
            if available != false { available = false }
            return
        }
        available = true
        reading = LightReadingValue(value: r.value, source: r.source)
        let elapsed = Date().timeIntervalSince(phaseStart)
        let roomLevel = LightCheck.mean(room) ?? r.value
        switch phase {
        case .room:
            room.append(r.value)
            if elapsed >= Self.roomSeconds { begin(.covered) }
        case .covered:
            covered.append(r.value)
            // Move on once it clearly went dark, or after the timeout (a sensor stuck bright).
            if r.value <= max(2, 0.25 * roomLevel) && elapsed >= 1 || elapsed >= Self.coverTimeout { begin(.bright) }
        case .bright:
            bright.append(r.value)
            if let b = camera.brightness { cameraMax = max(cameraMax ?? 0, b) }
            let lit = r.value >= max(3 * roomLevel, roomLevel + 50)
            if lit && elapsed >= 1 || elapsed >= Self.brightTimeout { evaluate() }
        default:
            break
        }
    }

    private func evaluate() {
        // Without a camera the technician confirms the flashlight instead.
        let cameraAvailable = camera.permission == .granted && camera.frames > 0
        let outcome = LightCheck.evaluate(room: room, covered: covered, bright: bright,
                                          cameraBrightness: cameraAvailable ? cameraMax : nil)
        let brightenedOrCameraKnown = cameraAvailable || !outcome.findings.contains { if case .doesNotBrighten = $0 { true } else { false } }
        if !brightenedOrCameraKnown {
            begin(.confirm)
            return
        }
        if outcome.verdict == .repeatStep {
            bright = []
            begin(.bright)
            prompt = String(localized: "The camera did not see the light either. Hold the flashlight closer to the camera and try again.")
            return
        }
        finish(cameraBrightness: cameraAvailable ? cameraMax : 1)
    }

    private func finish(cameraBrightness: Double?) {
        result = LightCheck.evaluate(room: room, covered: covered, bright: bright, cameraBrightness: cameraBrightness)
        resultID += 1
        begin(.done)
        if cameraStarted { camera.stop(); cameraStarted = false }
    }
}
