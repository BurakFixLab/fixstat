import Foundation
import Testing
@testable import MacSensors

/// macOS 27 moved the gauge data of AppleSmartBattery into child nodes
/// (AppleSmartBatteryPack / AppleSmartBatteryBank). Values from a MacBook Air M2 dump.
@Suite struct BatteryLayoutTests {
    static var top: [String: Any] { [
        "CycleCount": 479, "Voltage": 12968, "Amperage": 1496, "CurrentCapacity": 94, "MaxCapacity": 100,
        "DeviceName": "bq40z651", "ExternalConnected": true,
        "BatteryData": ["FullChargeCapacity": 3710, "NominalChargeCapacity": 3837, "RemainingCapacity": 3451,
                        "DesignCapacity": 4563, "CurrentCapacity": 94, "MaxCapacity": 100],
    ] }
    static var pack: [String: Any] { [
        "ID": 0, "BankCount": 3,
        "BatteryData": [
            "AppleRawCurrentCapacity": 3451, "AppleRawMaxCapacity": 3710, "DesignCapacity": 4563,
            "NominalChargeCapacity": 3837, "Temperature": 3159, "VirtualTemperature": 3159, "ChemID": 21353,
            "DataFlashWriteCount": 22042, "StateOfCharge": 93, "PermanentFailureStatus": 0,
            "BatteryCellDisconnectCount": 0,
            "LifetimeData": ["TotalOperatingTime": 34568, "MaximumTemperature": 45, "MinimumTemperature": 10],
        ] as [String: Any],
    ] }
    // Registry order is not guaranteed: BankID decides the cell order.
    static var banks: [[String: Any]] { [
        ["BankID": 2, "BatteryData": ["Qmax": 4344, "CellVoltage": 4319, "WeightedRa": 120, "DOD0": 5888, "PresentDOD": 16]],
        ["BankID": 0, "BatteryData": ["Qmax": 4317, "CellVoltage": 4327, "WeightedRa": 126, "DOD0": 5680, "PresentDOD": 14]],
        ["BankID": 1, "BatteryData": ["Qmax": 4327, "CellVoltage": 4321, "WeightedRa": 124, "DOD0": 5776, "PresentDOD": 15]],
    ] }

    @Test func macOS27LayoutReadsLikeTheClassicOne() {
        let props = BatteryReader.merged(Self.top, pack: Self.pack, banks: Self.banks)
        let b = BatteryReader.parse(props, includeSerial: false)
        #expect(b.designCapacity == 4563)
        #expect(b.rawMaxCapacity == 3710)
        #expect(b.rawCurrentCapacity == 3451)
        #expect(b.cellVoltages == [4327, 4321, 4319])
        #expect(b.cellQmax == [4317, 4327, 4344])
        #expect(b.cellResistance == [126, 124, 120])
        #expect(b.identity?.chemistryID == 21353)
        #expect(b.lifetime?.totalOperatingTime == 34568)
        #expect(b.temperature.map { abs($0 - 31.59) < 0.01 } == true)
        #expect(b.cycleCount == 479)

        let data = props["BatteryData"] as? [String: Any] ?? [:]
        #expect(data.intArray("DOD0") == [5680, 5776, 5888])
    }

    @Test func classicLayoutIsLeftAlone() {
        let classic: [String: Any] = [
            "DesignCapacity": 4382, "AppleRawMaxCapacity": 3200, "Temperature": 3000,
            "BatteryData": ["Qmax": [4103, 3967, 4076], "CellVoltage": [3900, 3910, 3905], "ChemID": 10037],
        ]
        // Even if children existed, values already on the battery node win.
        let props = BatteryReader.merged(classic, pack: Self.pack, banks: Self.banks)
        let b = BatteryReader.parse(props, includeSerial: false)
        #expect(b.designCapacity == 4382)
        #expect(b.rawMaxCapacity == 3200)
        #expect(b.cellQmax == [4103, 3967, 4076])
        #expect(b.cellVoltages == [3900, 3910, 3905])
        #expect(b.identity?.chemistryID == 10037)
    }

    @Test func incompleteBanksGiveNoCellArray() {
        var banks = Self.banks
        banks[1] = ["BankID": 0, "BatteryData": ["Qmax": 4317]]
        let props = BatteryReader.merged(Self.top, pack: Self.pack, banks: banks)
        let data = props["BatteryData"] as? [String: Any] ?? [:]
        #expect(data["CellVoltage"] == nil)
        #expect(data.intArray("Qmax") == [4317, 4327, 4344])
    }

    @Test func unreadableGaugeDataIsNotSuspicious() {
        // Nothing but the top-level basics: this macOS keeps the gauge data elsewhere.
        let b = BatteryReader.parse(Self.top, includeSerial: false)
        let check = PartCheck.battery(b, model: "Mac14,2", reference: PartsReference(batteries: [:], adapters: []))
        #expect(check.items.first { $0.id == "gaugeData" }?.status == .info)
    }
}
