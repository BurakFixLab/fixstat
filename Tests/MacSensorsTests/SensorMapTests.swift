import Foundation
import Testing
@testable import MacSensors

@Suite struct SensorMapTests {
    static var map: SensorMap {
        SensorMap(
            models: [
                "MacBookAir10,1": .init(chip: "Apple M1", board: "J313", description: nil, sensors: [
                    .init(key: "Tp2i", id: "cpu.pcluster.1", group: .cpu, confidence: .verified),
                    .init(key: "TN0n", id: "ssd.nand", group: .ssd, confidence: .estimated),
                ], ignored: ["TP1d"]),
            ],
            chips: [
                "Apple M1": .init(sensors: [
                    .init(key: "Tp2i", id: "cpu.pcluster.9", group: .cpu, confidence: .verified),
                    .init(key: "Tg1i", id: "gpu.cluster.1", group: .gpu, confidence: .verified),
                ]),
            ],
            patterns: [
                .init(key: "Tp([0-9a-zA-Z])i", hidName: nil, id: "cpu.pcluster.$1", group: .cpu, note: nil),
                .init(key: nil, hidName: "NAND CH([0-9]+) temp", id: "ssd.nand.$1", group: .ssd, note: nil),
                .init(key: "TB([0-9])T", hidName: nil, id: "battery.pack.$1", group: .battery, note: nil),
            ]
        )
    }

    @Test func modelEntryWinsOverChipAndPattern() {
        let r = Self.map.resolve(key: "Tp2i", hidName: "pACC MTR Temp Sensor2", model: "MacBookAir10,1", chip: "Apple M1")
        #expect(r == ResolvedSensor(id: "cpu.pcluster.1", group: .cpu, confidence: .verified, level: .model))
    }

    @Test func modelEntryKeepsItsConfidence() {
        let r = Self.map.resolve(key: "TN0n", hidName: "NAND CH0 temp", model: "MacBookAir10,1", chip: "Apple M1")
        #expect(r?.confidence == .estimated)
        #expect(r?.level == .model)
    }

    @Test func chipEntryIsAlwaysEstimated() {
        let r = Self.map.resolve(key: "Tg1i", hidName: nil, model: "MacBookPro17,1", chip: "Apple M1")
        #expect(r == ResolvedSensor(id: "gpu.cluster.1", group: .gpu, confidence: .estimated, level: .chip))
    }

    @Test func chipBeatsPattern() {
        let r = Self.map.resolve(key: "Tp2i", hidName: nil, model: "MacBookPro17,1", chip: "Apple M1")
        #expect(r?.id == "cpu.pcluster.9")
        #expect(r?.level == .chip)
    }

    @Test func patternFallbackWithCaptureGroups() {
        let r = Self.map.resolve(key: "Tp7i", hidName: nil, model: "Mac14,2", chip: "Apple M2")
        #expect(r == ResolvedSensor(id: "cpu.pcluster.7", group: .cpu, confidence: .estimated, level: .pattern))
        #expect(Self.map.resolve(key: nil, hidName: "NAND CH1 temp", model: "x", chip: nil)?.id == "ssd.nand.1")
    }

    @Test func patternMustMatchWholeKey() {
        #expect(Self.map.resolve(key: "Tp7ix", hidName: nil, model: "x", chip: nil) == nil)
        #expect(Self.map.resolve(key: "XTB0T", hidName: nil, model: "x", chip: nil) == nil)
    }

    @Test func unknownSensor() {
        #expect(Self.map.resolve(key: "Zzzz", hidName: "mystery", model: "x", chip: nil) == nil)
        #expect(Self.map.resolve(key: nil, hidName: nil, model: "x", chip: nil) == nil)
    }

    @Test func ignoredKeys() {
        #expect(Self.map.isIgnored(key: "TP1d", hidName: "PMU tdev1", model: "MacBookAir10,1"))
        #expect(!Self.map.isIgnored(key: "TP1d", hidName: nil, model: "Mac14,2"))
    }

    @Test func chipIgnoredAndDerivedKeys() {
        var map = Self.map
        map.chips["Apple M2"] = .init(sensors: [
            .init(key: "Tp01", id: "cpu.pcluster.1", group: .cpu, confidence: .estimated),
        ], ignored: ["Tf05"], derived: ["Tp00", "Tp02"])
        #expect(map.isIgnored(key: "Tp00", hidName: nil, model: "Mac14,2", chip: "Apple M2"))
        #expect(map.isIgnored(key: "Tf05", hidName: nil, model: "Mac14,2", chip: "Apple M2"))
        #expect(!map.isIgnored(key: "Tp01", hidName: nil, model: "Mac14,2", chip: "Apple M2"))
        #expect(!map.isIgnored(key: "Tp00", hidName: nil, model: "Mac14,2", chip: nil))
        // A model entry that names the sensor wins over the chip's lists.
        map.models["Mac14,2"] = .init(chip: "Apple M2", board: nil, description: nil, sensors: [
            .init(key: "Tp00", id: "cpu.pcluster.1", group: .cpu, confidence: .verified),
        ], ignored: ["TP1d"])
        #expect(!map.isIgnored(key: "Tp00", hidName: nil, model: "Mac14,2", chip: "Apple M2"))
        #expect(map.isIgnored(key: "TP1d", hidName: nil, model: "Mac14,2", chip: "Apple M2"))
        #expect(map.isIgnored(key: "Tp02", hidName: nil, model: "Mac14,2", chip: "Apple M2"))
    }

    @Test func userMapAddsToChipLists() {
        let base = SensorMap(chips: ["Apple M2": .init(sensors: [], derived: ["Tp00"])])
        let user = SensorMap(chips: ["Apple M2": .init(sensors: [
            .init(key: "Tp0c", id: "cpu.pcluster.9", group: .cpu, confidence: .estimated),
        ], ignored: ["Tf05"])])
        let merged = base.merged(with: user)
        #expect(merged.chips["Apple M2"]?.derived == ["Tp00"])
        #expect(merged.chips["Apple M2"]?.ignored == ["Tf05"])
        #expect(merged.chips["Apple M2"]?.sensors.map(\.key) == ["Tp0c"])
    }

    static func bundledMap() throws -> SensorMap {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SensorMaps/sensor-map.json")
        return try SensorMap.load(from: url)
    }

    /// Apple Silicon after M1: CPU / GPU die zones only exist as SMC keys, named per chip.
    @Test func bundledChipEntries() throws {
        let map = try Self.bundledMap()
        let m2Pro = map.resolve(key: "Tp01", hidName: nil, model: "Mac14,10", chip: "Apple M2 Pro")
        #expect(m2Pro == ResolvedSensor(id: "cpu.pcluster.1", group: .cpu, confidence: .estimated, level: .chip))
        #expect(map.resolve(key: "Te05", hidName: nil, model: "Mac16,12", chip: "Apple M4")?.id == "cpu.ecluster.1")
        #expect(map.isIgnored(key: "Tp00", hidName: nil, model: "Mac14,9", chip: "Apple M2 Pro"))
        #expect(map.isIgnored(key: "Tf06", hidName: nil, model: "Mac14,9", chip: "Apple M2 Pro"))
        for (chip, entry) in map.chips {
            let keys = entry.sensors.map(\.key)
            let hidden = Set((entry.ignored ?? []) + (entry.derived ?? []))
            #expect(Set(keys).count == keys.count, "duplicate key in \(chip)")
            #expect(hidden.isDisjoint(with: keys), "\(chip) names a key it also hides")
            let ids = entry.sensors.map(\.id)
            #expect(Set(ids).count == ids.count, "duplicate id in \(chip)")
            #expect(entry.sensors.allSatisfy { $0.group == .cpu || $0.group == .gpu })
        }
    }

    @Test func bundledMapDecodes() throws {
        let map = try Self.bundledMap()
        #expect(map.schemaVersion == 1)
        #expect(map.models["MacBookAir10,1"] != nil)
        // Every id must follow "<base>" or "<base>.<n>" with a known group prefix.
        for entry in map.models.values.flatMap(\.sensors) + map.chips.values.flatMap(\.sensors) {
            #expect(entry.id.hasPrefix(entry.group.rawValue + ".") || entry.group == .other || entry.group == .chassis,
                    "id \(entry.id) does not match group \(entry.group)")
        }
    }
}
