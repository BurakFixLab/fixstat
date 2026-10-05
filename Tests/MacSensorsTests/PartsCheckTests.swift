import Foundation
import Testing
@testable import MacSensors

@Suite struct PartsCheckTests {
    static var reference: PartsReference {
        PartsReference(
            batteries: ["MacBookAir10,1": .init(designCapacity: [4382], chemistryIDs: [10037], gauges: ["bq20z451"],
                                                cellCount: 3, cellVendors: ["ATL"], samples: 1)],
            adapters: [.init(id: "0x7002", name: "96W USB-C Power Adapter", manufacturer: "Apple Inc.", watts: 94,
                             profiles: [[5000, 3000], [9000, 3000], [15000, 3000], [20000, 4700]],
                             firmware: ["01070051"], samples: 1)]
        )
    }

    static var genuineBattery: BatteryInfo {
        var b = BatteryInfo()
        b.gaugeDeviceName = "bq20z451"
        b.designCapacity = 4382
        b.cellVoltages = [3900, 3910, 3905]
        b.cellQmax = [4103, 3967, 4076]
        b.cellResistance = [116, 149, 136]
        b.cycleCount = 359
        b.lifetime = BatteryLifetime(totalOperatingTime: 33078)
        b.identity = BatteryIdentity(chemistryID: 10037, manufacturerStrings: ["171", "002", "ATL"], dataFlashWriteCount: 6175)
        b.serial = "D86**************"
        return b
    }

    @Test func genuinePackIsConsistent() {
        let check = PartCheck.battery(Self.genuineBattery, model: "MacBookAir10,1", reference: Self.reference)
        #expect(check.verdict == .consistent)
        #expect(!check.items.contains { $0.status == .warn })
    }

    @Test func aftermarketPackIsSuspicious() {
        var b = Self.genuineBattery
        b.gaugeDeviceName = "sn27541"
        b.designCapacity = 5000
        b.cellResistance = nil
        b.cycleCount = 1
        let check = PartCheck.battery(b, model: "MacBookAir10,1", reference: Self.reference)
        #expect(check.verdict == .suspicious)
        let warned = Set(check.items.filter { $0.status == .warn }.map(\.id))
        #expect(warned.isSuperset(of: ["ref.gauge", "ref.designCapacity", "gaugeData", "cycleReset"]))
    }

    @Test func emptyReferenceListsAreNotChecked() {
        // No chemistry id was recorded for this model (older Intel gauges): no warning for it.
        var reference = Self.reference
        reference.batteries["MacBookAir10,1"]?.chemistryIDs = []
        let check = PartCheck.battery(Self.genuineBattery, model: "MacBookAir10,1", reference: reference)
        #expect(!check.items.contains { $0.id == "ref.chemistry" })
        #expect(check.verdict == .consistent)
    }

    @Test func unknownModelNeedsReference() {
        let check = PartCheck.battery(Self.genuineBattery, model: "Mac15,3", reference: Self.reference)
        #expect(check.verdict == .unknown)
        #expect(check.items.contains { $0.id == "noReference" })
    }

    static func adapterBattery(manufacturer: String, name: String, watts: Int, id: String) -> BatteryInfo {
        var b = BatteryInfo()
        b.externalConnected = true
        var a = AdapterInfo()
        a.manufacturer = manufacturer
        a.name = name
        a.ratedWatts = watts
        a.model = id
        a.firmwareVersion = "01070051"
        a.serial = "C4H**************"
        b.adapter = a
        var pd = PowerDeliveryInfo(sourceCapabilities: [], contract: nil, capabilityMismatch: nil, attachCount: nil,
                                   detachCount: nil, hardResetCount: nil, portIndex: 0)
        pd.adapterProfiles = [[5000, 3000], [9000, 3000], [15000, 3000], [20000, 4700]].map {
            PowerDataObject(kind: .fixed, maxVoltage: $0[0], minVoltage: nil, maxCurrent: $0[1], maxPower: nil, raw: 0)
        }
        pd.adapterSelectedIndex = 3
        b.powerDelivery = pd
        return b
    }

    @Test func genuineAdapter() {
        let b = Self.adapterBattery(manufacturer: "Apple Inc.", name: "96W USB-C Power Adapter", watts: 94, id: "0x7002")
        #expect(PartCheck.adapter(b, reference: Self.reference)?.verdict == .consistent)
    }

    @Test func foreignAdapter() {
        let b = Self.adapterBattery(manufacturer: "Generic", name: "96W USB-C Power Adapter", watts: 45, id: "0x1234")
        let check = PartCheck.adapter(b, reference: Self.reference)
        #expect(check?.verdict == .suspicious)
        #expect(check?.items.contains { $0.id == "adapter.nameWatts" && $0.status == .warn } == true)
    }

    @Test func noAdapter() {
        #expect(PartCheck.adapter(BatteryInfo(), reference: Self.reference) == nil)
    }

    @Test func bundledReferenceDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SensorMaps/parts.json")
        let reference = try PartsReference.load(from: url)
        #expect(reference.batteries["MacBookAir10,1"] != nil)
        #expect(!reference.adapters.isEmpty)
    }

    @Test func macOSHealthParsing() {
        let json = #"{"SPPowerDataType":[{"_name":"spbattery_information","sppower_battery_health_info":{"sppower_battery_health":"Check Battery","sppower_battery_health_maximum_capacity":"78%"}}]}"#
        let health = MacOSBatteryHealth.parse(Data(json.utf8))
        #expect(health?.condition == "Check Battery")
        #expect(health?.isGood == false)
    }
}
