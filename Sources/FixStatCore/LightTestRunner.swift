import Foundation
import MacSensors

/// Guided ambient light test: normal light → covered → flashlight, with the camera as a
/// second opinion on whether the flashlight really reached the sensor. Main thread.
public final class LightTestRunner {
    public enum Phase: Int { case idle, room, covered, bright, confirm, done }

    public private(set) var available: Bool?
    public private(set) var reading: LightReadingValue?
    public private(set) var phase = Phase.idle
    public private(set) var prompt: String?
    public private(set) var result: (verdict: LightCheck.Verdict, findings: [LightCheck.Finding])?
    /// Increases with every result (views react to a new result).
    public private(set) var resultID = 0
    public private(set) var cameraPermissionDenied = false
    public var onChange: (() -> Void)?

    private var room: [Double] = []
    private var covered: [Double] = []
    private var bright: [Double] = []
    private var cameraMax: Double?
    private var phaseStart = Date()
    private var timer: Timer?
    private let camera = CameraCapture()
    private var cameraStarted = false

    public static let roomSeconds = 3.0
    public static let coverTimeout = 12.0
    public static let brightTimeout = 15.0

    public init() {}

    public var roomMean: LightReadingValue? { value(LightCheck.mean(room)) }
    public var coveredMin: LightReadingValue? { value(covered.min()) }
    public var brightMax: LightReadingValue? { value(bright.max()) }

    private func value(_ v: Double?) -> LightReadingValue? {
        guard let v, let source = reading?.source else { return nil }
        return LightReadingValue(value: v, source: source)
    }

    public func prepare() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if cameraStarted { camera.stop(); cameraStarted = false }
    }

    public func start() {
        room = []
        covered = []
        bright = []
        cameraMax = nil
        result = nil
        begin(.room)
        if !cameraStarted {
            cameraStarted = true
            camera.start { [weak self] in
                guard let self else { return }
                cameraPermissionDenied = camera.permission == .denied || camera.permission == .noCamera
                onChange?()
            }
        }
    }

    public func confirmLight(_ wasOnSensor: Bool) {
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
        case .room: prompt = L("Keep the sensor uncovered in normal room light…")
        case .covered: prompt = L("Cover the sensor next to the camera with a finger.")
        case .bright: prompt = L("Shine a phone flashlight at the sensor next to the camera.")
        case .confirm: prompt = L("The camera could not confirm the light. Was the flashlight on the sensor?")
        case .idle, .done: prompt = nil
        }
    }

    private func tick() {
        defer { onChange?() }
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
            prompt = L("The camera did not see the light either. Hold the flashlight closer to the camera and try again.")
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

    /// Evidence for the report after a result.
    public var detail: String? {
        guard let result else { return nil }
        return result.findings.isEmpty
            ? L("Normal %@ · covered %@ · flashlight %@", LightText.value(roomMean), LightText.value(coveredMin),
                LightText.value(brightMax))
            : result.findings.map(LightText.finding).joined(separator: " ")
    }
}
