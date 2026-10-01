import Foundation
import Testing
@testable import MacSensors

@Suite struct ChipZoneAnalyzerTests {
    /// A synthetic M2-like recording: one P-zone triplet that is power gated for the first
    /// half, an E-zone triplet, a GPU pair, a cluster maximum, a calibration constant and
    /// an unexplained key.
    static func recording(apple: Bool = true, hidDie: Bool = false) -> SensorRecording {
        let keys = ["Tp00", "Tp01", "Tp02", "Tp04", "Te04", "Te05", "Te06", "Tg0e", "Tg0f", "Tf05", "Tq0x"]
        var sensors = keys.map { SensorDescriptor(source: .smc, key: $0, hidName: nil) }
        if hidDie { sensors.append(SensorDescriptor(source: .hid, key: "Tp2i", hidName: "pACC MTR Temp Sensor2")) }
        let system = SystemInfo(model: "Mac14,2", marketingName: nil, boardTarget: nil, chip: "Apple M2",
                                architecture: apple ? "arm64" : "x86_64", isAppleSilicon: apple, osVersion: "26")
        var recording = SensorRecording(system: system, startedAt: Date(), sensors: sensors)
        for t in 0..<60 {
            let load = Double(t) * 0.5
            let gated = t < 30
            let raw = gated ? 0 : 40 + load
            let peak = gated ? 8.4 : raw + 8 + Double(t % 3)
            let e = 33 + load * 0.2
            let g = gated ? 0 : 35 + load
            var values: [Double?] = [raw, raw + 6.7, peak, peak, e, e + 6.1, e + 9 + Double(t % 2),
                                     g, g + 5.7, 27.6, 30 + Double(t % 7)]
            if hidDie { values.append(45) }
            recording.samples.append(.init(t: Double(t), values: values))
        }
        return recording
    }

    @Test func findsZonesFromConstantOffsets() throws {
        let result = try #require(ChipZoneAnalyzer.analyze(Self.recording()))
        #expect(result.chip == "Apple M2")
        #expect(result.entry.sensors.map(\.key) == ["Tp01", "Te05", "Tg0f"])
        #expect(result.entry.sensors.map(\.id) == ["cpu.pcluster.1", "cpu.ecluster.1", "gpu.cluster.1"])
        #expect(result.entry.sensors.map(\.group) == [.cpu, .cpu, .gpu])
        // Raw and peak of each block, and Tp04 (an exact copy of the peak).
        #expect(Set(result.entry.derived ?? []) == ["Tp00", "Tp02", "Tp04", "Te04", "Te06", "Tg0e"])
        #expect(result.entry.ignored == ["Tf05"])
        #expect(result.review.isEmpty)
    }

    @Test func notForIntelOrHIDDieSensors() {
        #expect(ChipZoneAnalyzer.analyze(Self.recording(apple: false)) == nil)
        #expect(ChipZoneAnalyzer.analyze(Self.recording(hidDie: true)) == nil)
    }

    @Test func keyOrderFollowsTheSMCAlphabet() {
        let keys = ["Tp1A", "Tp0z", "Tp0a", "Tp0Z", "Tp09"]
        #expect(keys.sorted { ChipZoneAnalyzer.order($0) < ChipZoneAnalyzer.order($1) }
            == ["Tp09", "Tp0Z", "Tp0a", "Tp0z", "Tp1A"])
    }
}
