import Testing
@testable import MacSensors

@Suite struct ComponentEnergyTests {
    @Test func pmpWinsAndEnergyModelFillsTheRest() {
        // macOS 27: the PMGR CPU channels no longer move, so they drop out as zero; PMP counts.
        let model = [ComponentPower(name: "GPU Energy", watts: 0.07), ComponentPower(name: "PCIe Port 0 Energy", watts: 0.01)]
        let pmp = [ComponentPower(name: "ECPU", watts: 0.5), ComponentPower(name: "PCPU", watts: 6.5),
                   ComponentPower(name: "GPU", watts: 0.13), ComponentPower(name: "SOC_AON", watts: 0.001)]
        let merged = EnergySampler.merged(model: model, pmp: pmp)
        let names = merged.map(\.name)
        #expect(names.contains("CPU Energy"))
        #expect(merged.first { $0.name == "CPU Energy" }?.watts == 7.0)
        #expect(names.contains("GPU") && !names.contains("GPU Energy"))
        #expect(names.contains("PCIe Port 0 Energy"))
        #expect(names.contains("SOC_AON"))
    }

    @Test func energyModelAloneIsUnchanged() {
        let model = [ComponentPower(name: "CPU Energy", watts: 1), ComponentPower(name: "GPU Energy", watts: 0.1)]
        #expect(EnergySampler.merged(model: model, pmp: []) == model)
    }

    @Test func perCoreChannelsAreNotSummaries() {
        for name in ["PCORE0", "ECORE3", "PCPU2", "PACC0_CPU1", "ECPM", "PCPUDTL0a"] {
            #expect(!EnergySampler.isSummary(name), "\(name)")
        }
        for name in ["PCPU", "ECPU", "DRAM", "SOC_AON", "GPU SRAM", "CPU Energy"] {
            #expect(EnergySampler.isSummary(name), "\(name)")
        }
    }
}
