import Foundation
import Testing
@testable import MacSensors

@Suite struct PowerDeliveryTests {
    /// Source capabilities of a 60 W USB-C adapter as read from `PortControllerPortPDO`.
    static let adapterPDOs: [UInt32] = [134_320_428, 184_620, 307_500, 409_900]

    @Test func decodesFixedPDOs() {
        let pdos = Self.adapterPDOs.map(PowerDataObject.decode)
        #expect(pdos.map(\.kind) == [.fixed, .fixed, .fixed, .fixed])
        #expect(pdos.map(\.maxVoltage) == [5_000, 9_000, 15_000, 20_000])
        #expect(pdos.map(\.maxCurrent) == [3_000, 3_000, 3_000, 3_000])
        #expect(pdos.last?.power == 60_000)
    }

    @Test func decodesContractAgainstFixedPDO() {
        let pdos = Self.adapterPDOs.map(PowerDataObject.decode)
        let contract = PowerDeliveryContract.decode(1_124_319_472, sourceCapabilities: pdos)
        #expect(contract.objectPosition == 4)
        #expect(contract.voltage == 20_000)
        #expect(contract.operatingCurrent == 2_400)
        #expect(contract.maxCurrent == 2_400)
        #expect(contract.power == 48_000)
        #expect(!contract.capabilityMismatch)
    }

    @Test func decodesPPS() {
        // APDO: type 11, subtype 00, max 21 V (210 × 100 mV), min 3.3 V (33), 3 A (60 × 50 mA)
        let raw: UInt32 = (0b11 << 30) | (210 << 17) | (33 << 8) | 60
        let pdo = PowerDataObject.decode(raw)
        #expect(pdo.kind == .pps)
        #expect(pdo.maxVoltage == 21_000)
        #expect(pdo.minVoltage == 3_300)
        #expect(pdo.maxCurrent == 3_000)
        // RDO for PPS: position 1, 9 V (450 × 20 mV), 2 A (40 × 50 mA)
        let rdo: UInt32 = (1 << 28) | (450 << 9) | 40
        let contract = PowerDeliveryContract.decode(rdo, sourceCapabilities: [pdo])
        #expect(contract.voltage == 9_000)
        #expect(contract.operatingCurrent == 2_000)
    }

    @Test func contractOutsideCapabilities() {
        let contract = PowerDeliveryContract.decode((5 << 28) | (100 << 10) | 100, sourceCapabilities: [])
        #expect(contract.sourceObject == nil)
        #expect(contract.voltage == nil)
        #expect(contract.operatingCurrent == 1_000)
    }

    @Test func picksPortWithActiveContract() {
        let ports: [[String: Any]] = [
            ["PortControllerActiveContractRdo": 0, "PortControllerAttachCount": 3],
            ["PortControllerActiveContractRdo": 1_124_319_472,
             "PortControllerPortPDO": Self.adapterPDOs.map { NSNumber(value: $0) } + [0, 0],
             "PortControllerCapMismatch": 1, "PortControllerAttachCount": 15,
             "PortControllerDetachCount": 15, "PortControllerHardResetCount": 2],
        ]
        let info = PowerDeliveryInfo.parse(ports)
        #expect(info?.portIndex == 1)
        #expect(info?.sourceCapabilities.count == 4)
        #expect(info?.contract?.voltage == 20_000)
        #expect(info?.capabilityMismatch == true)
        #expect(info?.hardResetCount == 2)
    }

    @Test func manufacturerStrings() {
        let data = Data(hexString: "00000000100200012735000003313731033030320341544c003b000000000000")
        #expect(BatteryIdentity.strings(in: data) == ["171", "002", "ATL"])
        #expect(BatteryIdentity.strings(in: Data([0, 0, 0])) == [])
    }

    @Test func lifetimeAndResistanceParsing() {
        var props = BatteryParsingTests.sample
        var data = props["BatteryData"] as! [String: Any]
        data["WeightedRa"] = [116, 149, 136]
        data["ChemID"] = 10037
        data["LifetimeData"] = ["MaximumTemperature": 447, "MinimumTemperature": 83, "AverageTemperature": 247,
                                "TotalOperatingTime": 33078, "MaximumChargeCurrent": 3264,
                                "MaximumDischargeCurrent": -3159] as [String: Any]
        props["BatteryData"] = data
        let info = BatteryReader.parse(props, includeSerial: false)
        #expect(info.cellResistance == [116, 149, 136])
        #expect(info.identity?.chemistryID == 10037)
        #expect(info.lifetime?.maximumTemperature == 44.7)
        #expect(info.lifetime?.totalOperatingTime == 33078)
        #expect(info.lifetime?.maximumDischargeCurrent == -3159)
    }
}

extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            bytes.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}

@Suite struct CellAnalysisTests {
    @Test func flagsHighResistanceCell() {
        var info = BatteryInfo()
        info.cellVoltages = [4060, 4134, 4053]
        info.cellQmax = [4103, 3967, 4076]
        info.cellResistance = [116, 149, 136]
        let analysis = CellAnalysis(battery: info)
        #expect(analysis.suspects.map(\.number) == [2])
        #expect(analysis.cells[1].highResistance)
        #expect(!analysis.cells[1].lowCapacity) // −2.0 % is within the 3 % threshold
        #expect(abs((analysis.cells[1].resistanceDeviation ?? 0) - 0.1147) < 0.001)
    }

    @Test func balancedPack() {
        var info = BatteryInfo()
        info.cellQmax = [4000, 4010, 3990]
        info.cellResistance = [120, 125, 118]
        #expect(CellAnalysis(battery: info).suspects.isEmpty)
    }

    @Test func missingValues() {
        var info = BatteryInfo()
        info.cellVoltages = [3900, 3910]
        let analysis = CellAnalysis(battery: info)
        #expect(analysis.cells.count == 2)
        #expect(analysis.suspects.isEmpty)
    }
}
