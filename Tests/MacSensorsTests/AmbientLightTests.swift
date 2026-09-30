import Testing
@testable import MacSensors

@Suite struct LightCheckTests {
    @Test func healthySensor() {
        let r = LightCheck.evaluate(room: [85, 86, 87], covered: [1, 0, 0], bright: [900, 2400], cameraBrightness: 0.9)
        #expect(r.verdict == .passed)
        #expect(r.findings.isEmpty)
    }

    @Test func readsDarkWithLightOnIt() {
        // Screen dims by itself: the sensor stays low although the camera sees the flashlight.
        let r = LightCheck.evaluate(room: [2, 3, 2], covered: [0, 0], bright: [3, 4], cameraBrightness: 0.95)
        #expect(r.verdict == .failed)
        #expect(r.findings.contains { if case .doesNotBrighten = $0 { true } else { false } })
    }

    @Test func noFlashlightMeansRepeat() {
        let r = LightCheck.evaluate(room: [85, 86], covered: [1], bright: [88, 90], cameraBrightness: 0.2)
        #expect(r.verdict == .repeatStep)
        #expect(r.findings.contains(.noLightSeen))
    }

    @Test func stuckBright() {
        let r = LightCheck.evaluate(room: [400, 402], covered: [395, 398], bright: [2000], cameraBrightness: 0.9)
        #expect(r.verdict == .failed)
        #expect(r.findings.contains { if case .doesNotDarken = $0 { true } else { false } })
    }

    @Test func frozenValue() {
        let r = LightCheck.evaluate(room: [120, 120], covered: [120], bright: [120], cameraBrightness: 0.9)
        #expect(r.findings == [.frozen(120)])
    }

    @Test func unstableAndNoCamera() {
        let r = LightCheck.evaluate(room: [40, 150, 60], covered: [0], bright: [3000], cameraBrightness: nil)
        #expect(r.verdict == .failed)
        #expect(r.findings.contains { if case .unstable = $0 { true } else { false } })
    }

    @Test func missingSensor() {
        #expect(LightCheck.evaluate(room: [], covered: [], bright: [], cameraBrightness: nil).findings == [.notFound])
    }
}
