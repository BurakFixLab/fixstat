import Foundation
import Testing
@testable import MacSensors

@Suite struct CapacityTestTests {
    /// 2 A for one hour at 12 V from 100 % to 50 % on a 4000 mAh (FCC) pack.
    static func samples(fcc: Int = 4000, percentPerHour: Double = 50, remainingDrop: Int = 2000) -> [CapacitySample] {
        var result = [CapacitySample(time: 0, voltage: 12_600, amperage: -300, percent: 100, remaining: fcc,
                                     cells: [4200, 4200, 4200], temperature: 30, idle: true)]
        for step in 0...360 {
            let t = 20 + Double(step) * 10
            let fraction = Double(step) / 360
            result.append(CapacitySample(time: t, voltage: 12_000, amperage: -2000,
                                         percent: 100 - percentPerHour * fraction,
                                         remaining: fcc - Int(Double(remainingDrop) * fraction),
                                         cells: [4000, 3990 - (step > 300 ? 100 : 0), 4000], temperature: 35, idle: false))
        }
        return result
    }

    @Test func consistentPack() {
        let r = CapacityResult.compute(samples: Self.samples(), startedAt: Date(), stopReason: .targetReached,
                                       fullChargeCapacity: 4000, designCapacity: 4382)
        #expect(abs(r.deliveredMAh - 2000) < 1)
        #expect(abs(r.deliveredWh - 24) < 0.1)
        #expect(abs((r.averageWatts ?? 0) - 24) < 0.1)
        #expect(abs((r.extrapolatedCapacity ?? 0) - 4000) < 1)
        #expect(abs((r.gaugeAgreement ?? 0) - 1) < 0.01)
        #expect(abs((r.capacityAgreement ?? 0) - 1) < 0.01)
        // (12600 − 12000) mV / (2000 − 300) mA = 353 mΩ
        #expect(abs((r.packResistance ?? 0) - 352.9) < 0.5)
        #expect(r.maxCellSpread == 110)
        #expect(r.weakestCell == 2)
        #expect(r.findings.contains(.weakCell(2, 110)))
        #expect(!r.findings.contains(.tooShort))
    }

    @Test func gaugeOverstatesCapacity() {
        // The percentage falls twice as fast as the delivered charge justifies.
        let r = CapacityResult.compute(samples: Self.samples(percentPerHour: 80, remainingDrop: 3200),
                                       startedAt: Date(), stopReason: .targetReached,
                                       fullChargeCapacity: 4000, designCapacity: 4382)
        #expect(abs((r.extrapolatedCapacity ?? 0) - 2500) < 1)
        #expect(r.findings.contains { if case .capacityBelowGauge = $0 { true } else { false } })
        #expect(r.findings.contains { if case .gaugeMiscount = $0 { true } else { false } })
    }

    @Test func shortRunIsFlagged() {
        let short = Array(Self.samples().prefix(20))
        let r = CapacityResult.compute(samples: short, startedAt: Date(), stopReason: .stopped,
                                       fullChargeCapacity: 4000, designCapacity: 4382)
        #expect(r.findings.contains(.tooShort))
    }
}

@Suite struct CapacityShutdownTests {
    @Test func earlyShutdownIsAFinding() {
        let samples = CapacityTestTests.samples().filter { $0.idle || ($0.percent ?? 0) >= 78 }
        let r = CapacityResult.compute(samples: samples, startedAt: Date(), stopReason: .unexpectedShutdown,
                                       fullChargeCapacity: 4000, designCapacity: 4382)
        #expect(r.findings.contains { if case .shutdownAtCharge(let p) = $0 { p >= 78 && p < 79 } else { false } })
    }
}
