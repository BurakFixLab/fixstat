import Foundation
import Testing
@testable import MacSensors

@Suite struct DrainDetectiveTests {
    static let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A sleep or shutdown of `hours` on battery that lost `mAh`; DOD0 per cell (if given).
    static func segment(_ kind: DrainSegment.Kind = .sleep, hours: Double, mAh: Int, at offset: Double = 0,
                        dodBefore: [Int]? = nil, dodAfter: [Int]? = nil, onAdapter: Bool = false) -> DrainSegment {
        let begin = start.addingTimeInterval(offset * 3600)
        let qmax = [4000, 4000, 4000]
        let a = GaugeSnapshot(date: begin, remaining: 3000, charge: 70, externalConnected: onAdapter, isCharging: false,
                              cellQmax: qmax, cellDOD0: dodBefore, cellVoltages: nil)
        let b = GaugeSnapshot(date: begin.addingTimeInterval(hours * 3600), remaining: 3000 - mAh, charge: 65,
                              externalConnected: onAdapter, isCharging: false, cellQmax: qmax, cellDOD0: dodAfter,
                              cellVoltages: nil)
        return DrainSegment(kind: kind, start: a, end: b)
    }

    static func analysis(darkWakes: [(offset: Double, seconds: Int)] = [], settings: [String: String] = [:]) -> SleepAnalysis {
        var analysis = SleepAnalysis.parse(log: "")
        analysis.events = darkWakes.map {
            SleepAnalysis.Event(date: start.addingTimeInterval($0.offset * 3600), kind: .darkWake, reason: "Maintenance",
                                onBattery: true, charge: nil, duration: $0.seconds)
        }
        analysis.settings = settings
        return analysis
    }

    @Test func normalSleep() {
        let report = DrainReport.make(segments: [Self.segment(hours: 8, mAh: 64)], analysis: Self.analysis())
        #expect(report.sleep?.milliamps == 8)
        #expect(report.sleep?.level == .normal)
        #expect(report.conclusion == .normal)
    }

    @Test func darkWakesExplainTheDrain() {
        let wakes = (0..<30).map { (offset: Double($0) * 0.25 + 0.1, seconds: 60) }
        let report = DrainReport.make(segments: [Self.segment(hours: 8, mAh: 480)], analysis: Self.analysis(darkWakes: wakes))
        #expect(report.sleep?.level == .high)
        #expect(report.darkWakes == 30)
        #expect(report.conclusion == .software)
    }

    @Test func leakOnlyWhileAsleep() {
        let report = DrainReport.make(segments: [Self.segment(hours: 8, mAh: 560),
                                                 Self.segment(.off, hours: 10, mAh: 30, at: 20)],
                                      analysis: Self.analysis())
        #expect(report.sleep?.level == .high)
        #expect(report.off?.level == .normal)
        #expect(report.conclusion == .hardware(alwaysOn: false))
    }

    @Test func leakAlsoWhileShutDown() {
        let report = DrainReport.make(segments: [Self.segment(hours: 8, mAh: 560),
                                                 Self.segment(.off, hours: 10, mAh: 500, at: 20)],
                                      analysis: Self.analysis())
        #expect(report.conclusion == .hardware(alwaysOn: true))
        // Without a shutdown measurement the place stays open.
        let sleepOnly = DrainReport.make(segments: [Self.segment(hours: 8, mAh: 560)], analysis: Self.analysis())
        #expect(sleepOnly.conclusion == .hardware(alwaysOn: nil))
    }

    @Test func selfDischargingCell() {
        // Cell 2 (index 1) loses 328 / 16384 of its Qmax more than the others (≈ 80 mAh, 2 %);
        // cell 1 had the most charge.
        let segment = Self.segment(hours: 10, mAh: 400, dodBefore: [1000, 1200, 1100], dodAfter: [2600, 3128, 2700])
        let split = segment.cells
        #expect(split?.highestAtStart == 0)
        #expect(abs((split?.extra[1] ?? 0) - 328.0 / 16384 * 4000) < 0.01)
        let report = DrainReport.make(segments: [segment], analysis: Self.analysis())
        #expect(report.cellFindings.first?.cell == 1)
        #expect(report.cellFindings.first?.maybeBalancing == false)
        #expect(report.conclusion == .battery(cell: 1))
    }

    @Test func balancingIsNotSelfDischarge() {
        // The cell with the most charge loses more: balancing may have bled it.
        let segment = Self.segment(hours: 10, mAh: 60, dodBefore: [800, 1200, 1100], dodAfter: [1300, 1400, 1300])
        let report = DrainReport.make(segments: [segment], analysis: Self.analysis())
        #expect(report.cellFindings.first?.maybeBalancing == true)
        #expect(report.conclusion == .normal)
    }

    @Test func unusableSegmentsAreSkipped() {
        let charging = Self.segment(hours: 8, mAh: 400, onAdapter: true)
        let short = Self.segment(hours: 0.5, mAh: 100)
        #expect(DrainReport.make(segments: [charging, short], analysis: nil).conclusion == .noData)
        // No new open-circuit measurement: no cell split.
        #expect(Self.segment(hours: 3, mAh: 30, dodBefore: [1, 2, 3], dodAfter: [1, 2, 3]).cells == nil)
    }

    @Test func wakeSettings() {
        let report = DrainReport.make(segments: [Self.segment(hours: 8, mAh: 64)],
                                      analysis: Self.analysis(settings: ["powernap": "1", "tcpkeepalive": "0", "womp": "1"]))
        #expect(report.wakeSettings == ["powernap", "womp"])
    }
}
