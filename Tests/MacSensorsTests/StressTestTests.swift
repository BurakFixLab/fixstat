import Foundation
import Testing
@testable import MacSensors

@Suite struct StressTestTests {
    func sample(_ t: Double, cpu: Double = 60, gpu: Double = 50, battery: Double = 32,
                cells: [Int] = [3900, 3910, 3905], amperage: Int = -2000, soc: Double = 80,
                ac: Bool = false) -> StressSample {
        StressSample(time: t, cpu: cpu, gpu: gpu, ssd: 40, battery: battery, cellVoltages: cells,
                     amperage: amperage, stateOfCharge: soc, externalConnected: ac)
    }

    func analyze(_ samples: [StressSample], planned: TimeInterval = 10) -> StressTestResult {
        .analyze(samples: samples, startedAt: Date(), plannedDuration: planned, loads: ["cpu"],
                 hotThreshold: 55, imbalanceThreshold: 50)
    }

    @Test func healthyRunPasses() {
        let result = analyze((0...10).map { sample(Double($0), soc: 80 - Double($0) * 0.1) })
        #expect(result.passed)
        #expect(result.findings.isEmpty)
        #expect(result.maxCPU == 60)
        #expect(result.secondsAboveHot == 10)
        #expect(result.socStart == 80)
        #expect(result.averageCurrent == -2000)
        #expect(result.maxCellSpread == 10)
    }

    @Test func fanlessThrottlingIsNotAProblem() {
        let result = analyze((0...10).map { sample(Double($0), cpu: 100.1, gpu: 95) })
        #expect(result.passed)
    }

    @Test func reportsProblems() {
        var samples = (0...10).map { sample(Double($0)) }
        samples[5] = sample(5, cpu: 107, battery: 47, cells: [3250, 3400, 3395])
        let result = analyze(samples)
        #expect(!result.passed)
        #expect(result.findings.contains(.highChipTemperature(group: "cpu", celsius: 107, limit: 105)))
        #expect(result.findings.contains(.highBatteryTemperature(celsius: 47, limit: 45)))
        #expect(result.findings.contains(.cellVoltageSag(cell: 1, millivolts: 3250, limit: 3300)))
        #expect(result.findings.contains(.cellImbalance(millivolts: 150, limit: 100)))
    }

    @Test func adapterDeficitOnlyOnAC() {
        let onAC = analyze((0...10).map { sample(Double($0), amperage: -600, ac: true) })
        #expect(onAC.findings.contains(.adapterDeficit(averageMilliamps: -600)))
        let charging = analyze((0...10).map { sample(Double($0), amperage: 800, ac: true) })
        #expect(charging.findings.isEmpty)
    }

    @Test func stoppedEarly() {
        let result = analyze((0...10).map { sample(Double($0)) }, planned: 120)
        #expect(result.findings == [.stoppedEarly])
        #expect(result.passed)
    }
}
