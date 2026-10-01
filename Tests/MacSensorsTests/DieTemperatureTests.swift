import Testing
import FixStatCore
@testable import MacSensors

/// A power-gated Apple Silicon cluster reads 0 or its calibration offset; that is no reading.
@Suite struct DieTemperatureTests {
    static func sensor(_ group: SensorMap.Group) -> DisplaySensor {
        DisplaySensor(descriptor: SensorDescriptor(source: .smc, key: "Tp01", hidName: nil),
                      resolved: ResolvedSensor(id: "x.1", group: group, confidence: .estimated, level: .chip))
    }

    @Test func gatedClusterHasNoValue() {
        let cpu = Self.sensor(.cpu)
        #expect(MonitorCore.value(of: cpu, in: [cpu.id: 6.7]) == nil)
        #expect(MonitorCore.value(of: cpu, in: [cpu.id: 47.1]) == 47.1)
        #expect(MonitorCore.value(of: Self.sensor(.gpu), in: [cpu.id: 9.2]) == nil)
        // Board and chassis sensors can be cold.
        #expect(MonitorCore.value(of: Self.sensor(.chassis), in: [cpu.id: 6.7]) == 6.7)
    }

    @Test func menuBarTemperatureSkipsGatedZones() {
        let a = Self.sensor(.cpu)
        let b = DisplaySensor(descriptor: SensorDescriptor(source: .smc, key: "Te05", hidName: nil),
                              resolved: ResolvedSensor(id: "x.2", group: .cpu, confidence: .estimated, level: .chip))
        #expect(MonitorCore.cpuTemperature(sensors: [a, b], values: [a.id: 6.7, b.id: 39.8]) == 39.8)
    }
}
