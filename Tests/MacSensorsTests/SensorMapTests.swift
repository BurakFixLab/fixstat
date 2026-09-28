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

    @Test func bundledMapDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SensorMaps/sensor-map.json")
        let map = try SensorMap.load(from: url)
        #expect(map.schemaVersion == 1)
        #expect(map.models["MacBookAir10,1"] != nil)
        // Every id must follow "<base>" or "<base>.<n>" with a known group prefix.
        for entry in map.models.values.flatMap(\.sensors) {
            #expect(entry.id.hasPrefix(entry.group.rawValue + ".") || entry.group == .other || entry.group == .chassis,
                    "id \(entry.id) does not match group \(entry.group)")
        }
    }
}
