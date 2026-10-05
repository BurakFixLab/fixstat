import Testing
@testable import MacSensors

@Suite struct ThermalStatusTests {
    @Test func intelSpeedLimit() {
        let text = """
            2026-10-05 17:10:00 +0300 CPU Power notify
            \tCPU_Scheduler_Limit \t= 100
            \tCPU_Available_CPUs \t= 4
            \tCPU_Speed_Limit \t= 72
            """
        let status = ThermalStatus.parse(therm: text)
        #expect(status.cpuSpeedLimit == 72)
        #expect(status.schedulerLimit == 100)
    }

    @Test func appleSiliconHasNoLimit() {
        let text = "Note: No thermal warning level has been recorded\nNote: No CPU power status has been recorded\n"
        #expect(ThermalStatus.parse(therm: text).cpuSpeedLimit == nil)
    }
}
