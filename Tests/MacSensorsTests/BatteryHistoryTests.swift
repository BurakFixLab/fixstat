import Foundation
import Testing
@testable import MacSensors

@Suite struct BatteryHistoryTests {
    func makeStore() -> (BatteryHistoryStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fixstat-test-\(UUID().uuidString)")
        return (BatteryHistoryStore(directory: dir), dir)
    }

    func battery(soc: Double, amperage: Int, health: Double = 73.3, cycles: Int = 359) -> BatteryInfo {
        var info = BatteryInfo()
        info.stateOfCharge = soc
        info.amperage = amperage
        info.voltage = 12_000
        info.temperature = 30.5
        info.healthPercent = health
        info.nominalHealthPercent = 76.3
        info.cycleCount = cycles
        info.rawMaxCapacity = 3213
        info.designCapacity = 4382
        info.isCharging = amperage > 0
        info.externalConnected = amperage > 0
        return info
    }

    @Test func recordsAndReadsBack() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        store.record(battery(soc: 50, amperage: 1500), at: t0)
        store.record(battery(soc: 51, amperage: -800), at: t0.addingTimeInterval(60))

        let samples = store.samples()
        #expect(samples.count == 2)
        #expect(samples[0].stateOfCharge == 50)
        #expect(samples[0].amperage == 1500)
        #expect(samples[0].isCharging)
        #expect(samples[1].amperage == -800)
        #expect(!samples[1].externalConnected)
        #expect(samples[1].time == t0.addingTimeInterval(60))
        #expect(samples[0].health == 73.3)
    }

    @Test func oneHealthRecordPerDay() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        store.record(battery(soc: 50, amperage: 100), at: t0)
        store.record(battery(soc: 51, amperage: 100), at: t0.addingTimeInterval(60))
        store.record(battery(soc: 52, amperage: 100, health: 73.1, cycles: 360), at: t0.addingTimeInterval(86_400))
        let records = store.healthRecords()
        #expect(records.count == 2)
        #expect(records[1].cycleCount == 360)
        #expect(records[1].health == 73.1)
        // A new store instance continues where the file ends.
        let reopened = BatteryHistoryStore(directory: dir)
        reopened.record(battery(soc: 53, amperage: 100), at: t0.addingTimeInterval(86_400 + 60))
        #expect(reopened.healthRecords().count == 2)
    }

    @Test func pruneDropsOldSamplesOnly() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        store.record(battery(soc: 10, amperage: -1), at: now.addingTimeInterval(-31 * 86_400))
        store.record(battery(soc: 20, amperage: -1), at: now.addingTimeInterval(-3600))
        store.prune(now: now)
        #expect(store.samples().map(\.stateOfCharge) == [20])
        #expect(store.healthRecords().count == 2)
    }

    @Test func bucketing() {
        let t0 = Date(timeIntervalSince1970: 3600 * 1000)
        let samples = (0..<10).map { i in
            BatteryHistorySample(time: t0.addingTimeInterval(Double(i) * 60), stateOfCharge: Double(i),
                                 health: 70, amperage: i < 7 ? 1000 : -1000, voltage: 12_000,
                                 temperature: 30, isCharging: i < 7, externalConnected: true)
        }
        let buckets = BatteryHistoryStore.bucketed(samples, interval: 300)
        #expect(buckets.count == 2)
        #expect(buckets[0].stateOfCharge == 2)
        #expect(buckets[1].stateOfCharge == 7)
        #expect(buckets[1].amperage == -200) // (1000 + 1000 - 3000) / 5
        #expect(buckets[0].isCharging && !buckets[1].isCharging)
    }

    @Test func ignoresMalformedLines() {
        #expect(BatteryHistoryStore.parseSample("garbage") == nil)
        #expect(BatteryHistoryStore.parseSample("1,2") == nil)
        let line = BatteryHistoryStore.csvLine(BatteryHistorySample(
            time: Date(timeIntervalSince1970: 100), stateOfCharge: 12.5, health: nil, amperage: -5,
            voltage: 11_000, temperature: nil, isCharging: false, externalConnected: false))
        #expect(line == "100,12.5,,-5,11000,,0,0")
        #expect(BatteryHistoryStore.parseSample(Substring(line))?.health == nil)
    }
}
