import Foundation
import Testing
@testable import MacSensors

@Suite struct SMCDecodingTests {
    @Test func floatIsLittleEndian() {
        // 0x41e0ccc8 ≈ 28.1
        let value = SMCValue.decode(type: "flt ", bytes: [0xc8, 0xcc, 0xe0, 0x41])
        #expect(abs((value ?? 0) - 28.1) < 0.001)
    }

    @Test func unsignedIntegersAreBigEndian() {
        #expect(SMCValue.decode(type: "ui32", bytes: [0x00, 0x00, 0x05, 0xeb]) == 1515)
        #expect(SMCValue.decode(type: "ui16", bytes: [0x01, 0x00]) == 256)
        #expect(SMCValue.decode(type: "ui8 ", bytes: [0x02]) == 2)
    }

    @Test func signedIntegers() {
        #expect(SMCValue.decode(type: "si8 ", bytes: [0xff]) == -1)
        #expect(SMCValue.decode(type: "si16", bytes: [0xff, 0xfe]) == -2)
    }

    @Test func fixedPoint() {
        // sp78: 0x1c80 = 28.5
        #expect(SMCValue.decode(type: "sp78", bytes: [0x1c, 0x80]) == 28.5)
        // sp78 negative: 0xff00 = -1.0
        #expect(SMCValue.decode(type: "sp78", bytes: [0xff, 0x00]) == -1)
        // fpe2: 0x2328 >> 2 = 2250 rpm
        #expect(SMCValue.decode(type: "fpe2", bytes: [0x23, 0x28]) == 2250)
    }

    @Test func ioftIs48_16LittleEndian() {
        // 0x1c1999 / 65536 ≈ 28.1
        let value = SMCValue.decode(type: "ioft", bytes: [0x99, 0x19, 0x1c, 0, 0, 0, 0, 0])
        #expect(abs((value ?? 0) - 28.1) < 0.001)
    }

    @Test func nonNumericTypes() {
        #expect(SMCValue.decode(type: "ch8*", bytes: [0x41, 0x42]) == nil)
        #expect(SMCValue.decode(type: "{fds", bytes: [0, 0]) == nil)
    }

    @Test func fourCCRoundTrip() {
        #expect(FourCC("TB0T").description == "TB0T")
        #expect(FourCC("flt").description == "flt ")
        #expect(FourCC("#KEY").rawValue == 0x234b4559)
    }

    @Test func hidLocationIDIsSMCKey() {
        #expect(HIDReading.fourCC(1413951554) == "TG0B")
        #expect(HIDReading.fourCC(0) == nil)
    }
}

@Suite struct PrivacyTests {
    @Test func masksAllButVendorPrefix() {
        #expect(Privacy.mask("ABC1234567890XYZ") == "ABC*************")  // privacy:allow (fake test value)
        #expect(Privacy.mask("SHORT") == "*****")
    }

    @Test func masksSensitiveKeysRecursively() {
        let tree = JSONValue(propertyList: [
            "Serial": "ABC1234567890XYZ",  // privacy:allow (fake test value)
            "BatteryData": ["Serial": "DEF1234567890XYZ", "CycleCount": 12] as [String: Any],  // privacy:allow (fake test value)
            "AdapterDetails": ["SerialString": "GHI1234567"],  // privacy:allow (fake test value)
            "IOPlatformUUID": "01234567-89AB-CDEF-0123-456789ABCDEF",  // privacy:allow (fake test value)
        ] as [String: Any])
        let masked = Privacy.maskTree(tree)
        guard case .object(let root) = masked,
              case .object(let data) = root["BatteryData"],
              case .object(let adapter) = root["AdapterDetails"] else {
            Issue.record("unexpected structure")
            return
        }
        #expect(root["Serial"] == .string("ABC*************"))
        #expect(data["Serial"] == .string("DEF*************"))
        #expect(data["CycleCount"] == .number(12))
        #expect(adapter["SerialString"] == .string("GHI*******"))
        #expect(root["IOPlatformUUID"] == .string("012*********************************"))
    }
}

@Suite struct BatteryParsingTests {
    static var sample: [String: Any] { [
        "DeviceName": "bq20z451",
        "CycleCount": 359,
        "DesignCapacity": 4382,
        "AppleRawMaxCapacity": 3213,
        "AppleRawCurrentCapacity": 770,
        "NominalChargeCapacity": 3343,
        "CurrentCapacity": 25,
        "MaxCapacity": 100,
        "Temperature": 3011,
        "Voltage": 11178,
        "Amperage": NSNumber(value: Int64(-347)),
        "AvgTimeToFull": 65535,
        "AvgTimeToEmpty": 133,
        "IsCharging": false,
        "ExternalConnected": false,
        "AdapterDetails": ["FamilyCode": 0],
        "Serial": "XYZ0000000000TEST0",  // privacy:allow (fake test value)
        "BatteryData": ["CellVoltage": [3740, 3712, 3732], "Qmax": [4103, 3967, 4076]],
    ] }

    @Test func computesHealthAndCells() {
        let info = BatteryReader.parse(Self.sample, includeSerial: false)
        #expect(abs((info.healthPercent ?? 0) - 73.32) < 0.01)
        #expect(info.stateOfCharge == 25)
        #expect(info.temperature == 30.11)
        #expect(info.amperage == -347)
        #expect(info.cellVoltages == [3740, 3712, 3732])
        #expect(info.cellImbalance == 28)
        #expect(info.timeToFull == nil)
        #expect(info.timeToEmpty == 133)
        #expect(info.adapter == nil)
        #expect(info.serial == "XYZ***************")
    }

    @Test func serialOnlyWhenRequested() {
        let info = BatteryReader.parse(Self.sample, includeSerial: true)
        #expect(info.serial == "XYZ0000000000TEST0")  // privacy:allow (fake test value)
    }

    @Test func intelStyleCapacities() {
        var props = Self.sample
        props["CurrentCapacity"] = 2000
        props["MaxCapacity"] = 4000
        let info = BatteryReader.parse(props, includeSerial: false)
        #expect(info.stateOfCharge == 50)
    }
}
