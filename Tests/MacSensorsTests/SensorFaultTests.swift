import Testing
@testable import MacSensors

@Suite struct SensorFaultTests {
    static func sensor(_ key: String, _ group: SensorMap.Group, id: String? = nil,
                       level: ResolvedSensor.Level = .model) -> SensorFaultDetector.Sensor {
        SensorFaultDetector.Sensor(descriptor: SensorDescriptor(source: .smc, key: key, hidName: nil),
                                   resolved: ResolvedSensor(id: id ?? "\(group.rawValue).\(key)", group: group,
                                                            confidence: .estimated, level: level))
    }

    /// 90 samples: a slow rise from `from` by `rise`, with a little noise.
    static func ramp(_ from: Double, rise: Double = 5) -> [Double?] {
        (0..<90).map { i in from + rise * Double(i) / 90 + (i % 3 == 0 ? 0.13 : -0.07) }
    }

    static func detect(_ sensors: [SensorFaultDetector.Sensor], _ series: [[Double?]]) -> [SensorFault] {
        SensorFaultDetector.detect(sensors, series: series, seconds: 90)
    }

    @Test func healthyMacHasNoFaults() {
        let sensors = [Self.sensor("TN0n", .ssd), Self.sensor("TB0T", .battery), Self.sensor("Tp01", .cpu)]
        #expect(Self.detect(sensors, [Self.ramp(35), Self.ramp(30, rise: 1), Self.ramp(45, rise: 10)]).isEmpty)
    }

    @Test func openShortAndNoReading() {
        let sensors = [Self.sensor("TH0R", .ssd), Self.sensor("TP3d", .other), Self.sensor("TB1T", .battery),
                       Self.sensor("TN0n", .ssd)]
        let series: [[Double?]] = [Array(repeating: -54, count: 90), Array(repeating: 245, count: 90),
                                   Array(repeating: -127, count: 90), Self.ramp(35)]
        let faults = Self.detect(sensors, series)
        #expect(faults.map(\.kind) == [.open, .short, .noReading])
        #expect(faults.allSatisfy { $0.known })
    }

    @Test func unpopulatedChannelOnlyCountsForKnownSensors() {
        // Apple Silicon PMU channel without an NTC: about −22 °C.
        let channel: [Double?] = (0..<90).map { _ in -22.1 }
        #expect(Self.detect([Self.sensor("TP1d", .other)], [channel]).map(\.kind) == [.open])
        #expect(Self.detect([Self.sensor("TP1d", .other, level: .pattern)], [channel]).isEmpty)
        // A guessed key that never reads may not exist (TC3C on a dual-core CPU).
        let none: [Double?] = Array(repeating: -127, count: 90)
        #expect(Self.detect([Self.sensor("TC3C", .other, level: .pattern)], [none]).isEmpty)
    }

    @Test func occasionalNoReadingIsTolerated() {
        var values = Self.ramp(40)
        for i in stride(from: 0, to: 90, by: 10) { values[i] = -127 }
        #expect(Self.detect([Self.sensor("TC0P", .other)], [values]).isEmpty)
    }

    @Test func frozenOnlyWhenPeersMove() {
        let stuck: [Double?] = Array(repeating: 31.5, count: 90)
        let sensors = [Self.sensor("Ts0P", .chassis), Self.sensor("Ts1P", .chassis)]
        #expect(Self.detect(sensors, [stuck, Self.ramp(30, rise: 6)]).map(\.kind) == [.frozen])
        #expect(Self.detect(sensors, [stuck, Self.ramp(30, rise: 1)]).isEmpty)
    }

    @Test func dieZonesAndVirtualKeysAreNotJudged() {
        // ANE / ISP of the M1 read 30.0 while power gated; a gated cluster reads its offset.
        let constant: [Double?] = Array(repeating: 30, count: 90)
        let gated: [Double?] = Array(repeating: 7.4, count: 90)
        let sensors = [Self.sensor("Ta1i", .other, id: "soc.ane.1"), Self.sensor("Tp09", .cpu),
                       Self.sensor("TVA0", .chassis), Self.sensor("Ts0P", .chassis)]
        let faults = Self.detect(sensors, [constant, gated, Array(repeating: 6.5, count: 90), Self.ramp(30, rise: 8)])
        #expect(faults.isEmpty)
    }

    @Test func tooColdAgainstAWarmMac() {
        let sensors = [Self.sensor("TW0P", .other), Self.sensor("TN0n", .ssd), Self.sensor("TB0T", .battery)]
        let faults = Self.detect(sensors, [Self.ramp(4, rise: 1), Self.ramp(38), Self.ramp(32)])
        #expect(faults.map(\.kind) == [.tooCold])
    }
}
