import Foundation
import Testing
@testable import MacSensors

@Suite struct DeadCellTests {
    /// A pack left discharged too long (MacBookAir10,1 at the bench): cell 1 at 0.3 V, the
    /// gauge back on its defaults (cycle 1, every Qmax = design capacity, no resistance).
    static var deepDischarged: BatteryInfo {
        var b = BatteryInfo()
        b.designCapacity = 4382
        b.cycleCount = 1
        b.cellVoltages = [300, 3600, 3600]
        b.cellQmax = [4382, 4382, 4382]
        return b
    }

    @Test func deadCellIsFlagged() {
        let analysis = CellAnalysis(battery: Self.deepDischarged)
        #expect(analysis.suspects.map(\.number) == [1])
        #expect(analysis.cells[0].lowVoltage)
        #expect(!analysis.cells[1].lowVoltage)
    }

    @Test func defaultQmaxIsNotEvidence() {
        #expect(CellAnalysis(battery: Self.deepDischarged).defaultQmax)
        var learned = Self.deepDischarged
        learned.cellQmax = [4103, 3967, 4076]
        #expect(!CellAnalysis(battery: learned).defaultQmax)
    }

    @Test func missingVoltagesAreNotDeadCells() {
        var b = Self.deepDischarged
        b.cellVoltages = [0, 0, 0]
        #expect(CellAnalysis(battery: b).cells.allSatisfy { !$0.lowVoltage })
    }
}
