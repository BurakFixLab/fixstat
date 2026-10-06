import CMacSensors
import Foundation
import Testing
@testable import MacSensors

@Suite struct ATAHealthTests {
    /// SMART data with the given attributes (id, current, worst, raw) and thresholds (id: value).
    static func smart(_ attributes: [(Int, Int, Int, UInt64)], thresholds: [Int: Int] = [:]) -> ([UInt8], [UInt8]) {
        var data = [UInt8](repeating: 0, count: 512)
        var limits = [UInt8](repeating: 0, count: 512)
        data[0] = 0x10
        for (entry, attribute) in attributes.enumerated() {
            let offset = 2 + entry * 12
            data[offset] = UInt8(attribute.0)
            data[offset + 3] = UInt8(attribute.1)
            data[offset + 4] = UInt8(attribute.2)
            for byte in 0..<6 { data[offset + 5 + byte] = UInt8((attribute.3 >> (8 * UInt64(byte))) & 0xFF) }
            if let limit = thresholds[attribute.0] {
                limits[offset] = UInt8(attribute.0)
                limits[offset + 1] = UInt8(limit)
            }
        }
        return (data, limits)
    }

    @Test func appleSanDiskCountersInMiB() throws {
        // APPLE SSD SD0128F (MacBookAir6,1): values as DriveDx and FixStat read them.
        let (data, limits) = Self.smart([(169, 100, 100, 863_462_491_872), (173, 176, 176, 2_319_331_033_727),
                                         (174, 100, 100, 67_315_794), (175, 100, 100, 50_407_295)],
                                        thresholds: [169: 10, 173: 100])
        var health = try #require(ATAHealth.parse(data: data, thresholds: limits, exceeded: 0))
        #expect(health.bytesWritten == nil)
        health.model = "APPLE SSD SD0128F"
        #expect(health.bytesWritten == Double(50_407_295) * 1_048_576)
        #expect(health.bytesRead == Double(67_315_794) * 1_048_576)
        #expect(health.eraseCounts?.average == 639)
        #expect(health.eraseCounts?.maximum == 743)
        #expect(health.eraseCounts?.minimum == 540)
        #expect(health.lifeLeft?.attribute == 169)
    }

    @Test func parsesASamsungStyleSSD() throws {
        // Power-on hours with minutes packed above the low 32 bits, 241 in LBAs.
        let (data, limits) = Self.smart([(9, 95, 95, 0x0012_0000_1F40), (12, 99, 99, 1503), (177, 97, 97, 112),
                                         (194, 70, 55, 0x0028_0015_001E), (241, 99, 99, 20_000_000_000)],
                                        thresholds: [177: 0, 9: 0])
        let health = try #require(ATAHealth.parse(data: data, thresholds: limits, exceeded: 0))
        #expect(health.powerOnHours == 8000)
        #expect(health.powerCycles == 1503)
        #expect(health.temperature == 30)
        #expect(health.attribute(241)?.raw == 20_000_000_000, "raw \(String(describing: health.attribute(241)))")
        #expect(health.bytesWritten == 10_240_000_000_000)
        #expect(health.lifeLeft?.percent == 97)
        #expect(health.lifeLeft?.attribute == 177)
        #expect(health.thresholdExceeded == false)
        #expect(health.failingAttributes.isEmpty)
    }

    @Test func lifeAttributePriority() throws {
        // 231 (SSD Life Left) wins over 173; values above 100 are no percentage.
        let (data, limits) = Self.smart([(173, 88, 88, 900), (231, 92, 92, 0), (233, 200, 200, 0)])
        #expect(ATAHealth.parse(data: data, thresholds: limits, exceeded: -1)?.lifeLeft?.attribute == 231)
        let (only173, none) = Self.smart([(173, 88, 88, 900), (233, 200, 200, 0)])
        #expect(ATAHealth.parse(data: only173, thresholds: none, exceeded: -1)?.lifeLeft?.attribute == 173)
    }

    @Test func failingAttributeAndDriveVerdict() throws {
        let (data, limits) = Self.smart([(5, 9, 9, 2400), (197, 100, 100, 12)], thresholds: [5: 10])
        let health = try #require(ATAHealth.parse(data: data, thresholds: limits, exceeded: 1))
        #expect(health.failingAttributes.map(\.id) == [5])
        #expect(health.reallocatedSectors == 2400)
        #expect(health.pendingSectors == 12)
        #expect(health.thresholdExceeded == true)
    }

    @Test func emptyTableIsNoData() {
        #expect(ATAHealth.parse(data: [UInt8](repeating: 0, count: 512), thresholds: [], exceeded: -1) == nil)
    }

    @Test func healthPercentOfBothKinds() {
        var nvme = SSDInfo()
        nvme.health = NVMeHealth(criticalWarning: 0, temperature: 30, availableSpare: 100, availableSpareThreshold: 10,
                                 percentageUsed: 3, bytesRead: 0, bytesWritten: 0, powerCycles: 0, powerOnHours: 0,
                                 unsafeShutdowns: 0, mediaErrors: 0, errorLogEntries: 0)
        #expect(nvme.healthPercent == 97)
        nvme.health?.percentageUsed = 130
        #expect(nvme.healthPercent == 0)
        var ata = SSDInfo()
        let (data, limits) = Self.smart([(177, 91, 91, 0)])
        ata.ata = ATAHealth.parse(data: data, thresholds: limits, exceeded: 0)
        #expect(ata.healthPercent == 91)
    }
}

@Suite struct DiskIOStatisticsTests {
    @Test func countersFromTheDriver() throws {
        let stats = try #require(DiskIOStatistics(["Operations (Read)": 4_540_273, "Bytes (Read)": 170_894_938_112,
                                                   "Errors (Read)": 2, "Retries (Read)": 5, "Errors (Write)": 0,
                                                   "Bytes (Write)": 92_284_043_264] as [String: Any]))
        #expect(stats.errors == 2)
        #expect(stats.retries == 5)
        #expect(stats.bytesWritten == 92_284_043_264)
        // A partition's statistics (no operation counts) are not the driver's.
        #expect(DiskIOStatistics(["Foo": 1] as [String: Any]) == nil)
    }

    @Test func smartStepsForTheTechnician() {
        let steps: [kern_return_t] = [0, 0, 0, kern_return_t(bitPattern: 0xe00002ca), kern_return_t(bitPattern: 0xe00002ca),
                                      kern_return_t(bitPattern: 0xe00002c7), FSATAStepNotRun]
        #expect(ATADrive.describe(steps: steps)
            == "plugin ok · interface ok · identify ok · read 0xe00002ca · retry 0xe00002ca · parent plugin 0xe00002c7")
    }
}
