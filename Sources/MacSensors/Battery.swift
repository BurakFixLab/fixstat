import Foundation
import IOKit

/// Power adapter as reported in `AdapterDetails`.
public struct AdapterInfo: Codable, Sendable, Equatable {
    /// Negotiated / rated adapter power in W.
    public var ratedWatts: Int?
    /// Negotiated voltage in mV.
    public var voltage: Int?
    /// Negotiated current limit in mA.
    public var current: Int?
    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var description: String?
    public var familyCode: Int?
    public var isWireless: Bool?
    public var firmwareVersion: String?
    public var hardwareVersion: String?
    /// Masked unless serial output is explicitly requested.
    public var serial: String?
}

/// Input power telemetry (`PowerTelemetryData`, Apple Silicon).
public struct PowerTelemetry: Codable, Sendable, Equatable {
    /// Power drawn from the adapter in mW — what the adapter actually delivers.
    public var systemPowerIn: Int?
    /// Input voltage in mV.
    public var systemVoltageIn: Int?
    /// Input current in mA.
    public var systemCurrentIn: Int?
    /// `SystemLoad` as reported, in mW. Observed to equal SystemPowerIn − BatteryPower.
    public var systemLoad: Int?
    /// `BatteryPower` as reported, in mW. Observed negative both while charging
    /// and discharging (M1, macOS 26) — do not rely on its sign; use
    /// `BatteryInfo.batteryPowerWatts` (voltage × signed amperage) instead.
    public var batteryPower: Int?
    /// Adapter efficiency loss in mW.
    public var adapterEfficiencyLoss: Int?
}

/// Charger state (`ChargerData`).
public struct ChargerInfo: Codable, Sendable, Equatable {
    /// Requested charging current in mA.
    public var chargingCurrent: Int?
    /// Requested charging voltage in mV.
    public var chargingVoltage: Int?
    /// Bit field; Apple does not document the bits. 0 = charging normally.
    public var notChargingReason: Int?
    public var slowChargingReason: Int?
    public var chargerInhibitReason: Int?
    /// As reported (`TimeChargingThermallyLimited`).
    public var timeChargingThermallyLimited: Int?
    public var vacVoltageLimit: Int?
}

/// What the gauge recorded over the life of the pack (`BatteryData.LifetimeData`).
public struct BatteryLifetime: Codable, Sendable, Equatable {
    /// Hours.
    public var totalOperatingTime: Int? = nil
    /// °C
    public var maximumTemperature: Double? = nil
    public var minimumTemperature: Double? = nil
    public var averageTemperature: Double? = nil
    /// mA
    public var maximumChargeCurrent: Int? = nil
    /// mA (negative)
    public var maximumDischargeCurrent: Int? = nil
    /// mV
    public var maximumPackVoltage: Int? = nil
    public var minimumPackVoltage: Int? = nil
}

/// Pack identification that is not a serial number.
public struct BatteryIdentity: Codable, Sendable, Equatable {
    /// Gauge chemistry id (`BatteryData.ChemID`).
    public var chemistryID: Int?
    /// Text fields found in `ManufacturerData` (e.g. lot codes and the cell maker, "ATL").
    public var manufacturerStrings: [String]
    /// Gauge data flash write count.
    public var dataFlashWriteCount: Int?

    /// Length-prefixed text fields (2…16 letters, digits, space or dash) in the
    /// manufacturer data block. Single bytes are not treated as text.
    public static func strings(in data: Data) -> [String] {
        let bytes = [UInt8](data)
        var result: [String] = []
        var index = 0
        while index < bytes.count {
            let length = Int(bytes[index])
            if (2...16).contains(length), index + length < bytes.count {
                let slice = bytes[(index + 1)...(index + length)]
                let allowed: (UInt8) -> Bool = { byte in
                    (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte)
                        || (0x61...0x7a).contains(byte) || byte == 0x20 || byte == 0x2d
                }
                if slice.allSatisfy(allowed) {
                    result.append(String(decoding: slice, as: UTF8.self))
                    index += length + 1
                    continue
                }
            }
            index += 1
        }
        return result
    }
}

/// Snapshot of `AppleSmartBattery`.
public struct BatteryInfo: Codable, Sendable, Equatable {
    public var gaugeDeviceName: String?
    public var cycleCount: Int?
    public var designCycleCount: Int?
    /// mAh
    public var designCapacity: Int?
    /// mAh, `AppleRawMaxCapacity` (gauge FCC)
    public var rawMaxCapacity: Int?
    /// mAh, `AppleRawCurrentCapacity` (gauge RM)
    public var rawCurrentCapacity: Int?
    /// mAh, `NominalChargeCapacity`
    public var nominalChargeCapacity: Int?
    /// User-visible state of charge in %.
    public var stateOfCharge: Double?
    /// rawMaxCapacity / designCapacity in %.
    public var healthPercent: Double?
    /// nominalChargeCapacity / designCapacity in % (closer to what macOS shows).
    public var nominalHealthPercent: Double?
    /// °C
    public var temperature: Double?
    /// °C, `VirtualTemperature`
    public var virtualTemperature: Double?
    /// mV
    public var voltage: Int?
    /// mA, positive = charging, negative = discharging.
    public var amperage: Int?
    /// mA
    public var instantAmperage: Int?
    /// Battery power in W (voltage × amperage), positive = charging.
    public var batteryPowerWatts: Double?
    /// Power consumed by the system in W. On AC: input − battery power −
    /// adapter loss; on battery: the discharge power.
    public var systemPowerWatts: Double?
    public var isCharging: Bool?
    public var externalConnected: Bool?
    public var fullyCharged: Bool?
    /// Minutes, `AvgTimeToFull` (nil when not applicable).
    public var timeToFull: Int?
    /// Minutes, `AvgTimeToEmpty` (nil when not applicable).
    public var timeToEmpty: Int?
    /// Minutes, `TimeRemaining` as reported.
    public var timeRemaining: Int?
    /// mV per cell (`BatteryData.CellVoltage`).
    public var cellVoltages: [Int]?
    /// max − min cell voltage in mV.
    public var cellImbalance: Int?
    /// mAh per cell (`BatteryData.Qmax`).
    public var cellQmax: [Int]?
    /// Weighted cell resistance per cell (`BatteryData.WeightedRa`), gauge units.
    /// Relative differences between cells matter; the absolute unit is not documented.
    public var cellResistance: [Int]?
    /// Number of per-cell resistance tables (`BatteryData.RaTableRaw`). Intel gauges publish these
    /// learned tables but no `WeightedRa`.
    public var cellResistanceTables: Int?
    /// Gauge-internal state of charge in % (`BatteryData.StateOfCharge`).
    public var gaugeStateOfCharge: Int?
    public var permanentFailureStatus: Int?
    public var cellDisconnectCount: Int?
    public var adapter: AdapterInfo?
    public var powerTelemetry: PowerTelemetry?
    public var charger: ChargerInfo?
    public var powerDelivery: PowerDeliveryInfo?
    public var lifetime: BatteryLifetime?
    public var identity: BatteryIdentity?
    /// Pack serial number; masked unless serial output is explicitly requested.
    public var serial: String?
}

public enum BatteryReader {
    static let registryClass = "AppleSmartBattery"

    /// The raw registry properties of the battery, or nil if the Mac has none. Where the gauge
    /// data lives in child nodes (macOS 27), their properties are added under
    /// `AppleSmartBatteryPack` / `AppleSmartBatteryBanks` so raw dumps keep them.
    public static func rawProperties() -> [String: Any]? {
        guard let nodes = registryNodes() else { return nil }
        var props = nodes.top
        if let pack = nodes.pack { props[packKey] = pack }
        if !nodes.banks.isEmpty { props[banksKey] = nodes.banks }
        return props
    }

    /// The battery's properties in the classic layout (everything on `AppleSmartBattery`),
    /// whichever layout this macOS publishes.
    public static func properties() -> [String: Any]? {
        guard let nodes = registryNodes() else { return nil }
        return merged(nodes.top, pack: nodes.pack, banks: nodes.banks)
    }

    public static func read(includeSerial: Bool = false) -> BatteryInfo? {
        guard let props = properties() else { return nil }
        return parse(props, includeSerial: includeSerial)
    }

    static let packKey = "AppleSmartBatteryPack"
    static let banksKey = "AppleSmartBatteryBanks"

    private static func registryNodes() -> (top: [String: Any], pack: [String: Any]?, banks: [[String: Any]])? {
        let service = IOServiceGetMatchingService(ioMainPort, IOServiceMatching(registryClass))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let top = Registry.properties(of: service) else { return nil }
        let pack = Registry.descendants(of: service, className: "AppleSmartBatteryPack").first
        let banks = Registry.descendants(of: service, className: "AppleSmartBatteryBank")
        return (top, pack, banks)
    }

    /// Top-level keys that macOS 27 moved into the pack's (or the battery's own) `BatteryData`.
    static let movedTopLevelKeys = [
        "DesignCapacity", "AppleRawMaxCapacity", "AppleRawCurrentCapacity", "NominalChargeCapacity",
        "Temperature", "VirtualTemperature", "PermanentFailureStatus", "BatteryCellDisconnectCount",
    ]
    /// Per-cell `BatteryData` arrays that macOS 27 split into one value per bank.
    static let perCellKeys = ["CellVoltage", "Qmax", "WeightedRa", "DOD0", "PresentDOD"]

    /// Fills what the classic layout has but `top` lacks from the macOS 27 child nodes:
    /// pack `BatteryData` → `BatteryData` and the moved top-level keys, bank values (ordered by
    /// `BankID`) → the per-cell arrays. Values already present are never replaced, so on a
    /// macOS that still publishes the classic layout nothing changes.
    static func merged(_ top: [String: Any], pack: [String: Any]?, banks: [[String: Any]]) -> [String: Any] {
        var props = top
        var data = top.dict("BatteryData") ?? [:]
        if let packData = pack?.dict("BatteryData") {
            for (key, value) in packData where data[key] == nil { data[key] = value }
        }
        let bankData = banks
            .sorted { ($0.int("BankID") ?? 0) < ($1.int("BankID") ?? 0) }
            .compactMap { $0.dict("BatteryData") }
        if !bankData.isEmpty {
            for key in perCellKeys where data[key] == nil {
                let values = bankData.compactMap { $0.int(key) }
                if values.count == bankData.count { data[key] = values.map { NSNumber(value: $0) } }
            }
        }
        for key in movedTopLevelKeys where props[key] == nil {
            if let value = data[key] { props[key] = value }
        }
        if !data.isEmpty { props["BatteryData"] = data }
        return props
    }

    /// Sentinel used by the gauge for "not available" time values.
    static let unavailableTime = 65535

    public static func parse(_ props: [String: Any], includeSerial: Bool) -> BatteryInfo {
        var info = BatteryInfo()
        let data = props.dict("BatteryData") ?? [:]

        info.gaugeDeviceName = props.string("DeviceName")
        info.cycleCount = props.int("CycleCount")
        info.designCycleCount = props.int("DesignCycleCount9C")
        info.designCapacity = props.int("DesignCapacity")
        info.rawMaxCapacity = props.int("AppleRawMaxCapacity")
        info.rawCurrentCapacity = props.int("AppleRawCurrentCapacity")
        info.nominalChargeCapacity = props.int("NominalChargeCapacity")

        // On Apple Silicon CurrentCapacity/MaxCapacity are percentages (MaxCapacity = 100),
        // on Intel both are mAh. The ratio is correct in both cases.
        if let current = props.int("CurrentCapacity"), let max = props.int("MaxCapacity"), max > 0 {
            info.stateOfCharge = Double(current) / Double(max) * 100
        }
        if let design = info.designCapacity, design > 0 {
            info.healthPercent = info.rawMaxCapacity.map { Double($0) / Double(design) * 100 }
            info.nominalHealthPercent = info.nominalChargeCapacity.map { Double($0) / Double(design) * 100 }
        }

        info.temperature = props.int("Temperature").map { Double($0) / 100 }
        info.virtualTemperature = props.int("VirtualTemperature").map { Double($0) / 100 }
        info.voltage = props.int("Voltage")
        info.amperage = props.int("Amperage")
        info.instantAmperage = props.int("InstantAmperage")
        if let v = info.voltage, let a = info.amperage {
            info.batteryPowerWatts = Double(v) * Double(a) / 1_000_000
        }
        info.isCharging = props.bool("IsCharging")
        info.externalConnected = props.bool("ExternalConnected")
        info.fullyCharged = props.bool("FullyCharged")

        func time(_ key: String) -> Int? {
            guard let value = props.int(key), value != unavailableTime, value >= 0 else { return nil }
            return value
        }
        info.timeToFull = time("AvgTimeToFull")
        info.timeToEmpty = time("AvgTimeToEmpty")
        info.timeRemaining = time("TimeRemaining")

        let cells = data.intArray("CellVoltage") ?? props.intArray("CellVoltage")
        if let cells, !cells.isEmpty {
            info.cellVoltages = cells
            if let lo = cells.min(), let hi = cells.max() {
                info.cellImbalance = hi - lo
            }
        }
        info.cellQmax = data.intArray("Qmax")
        info.cellResistance = data.intArray("WeightedRa")
        if let tables = data["RaTableRaw"] as? [Any], !tables.isEmpty { info.cellResistanceTables = tables.count }
        if let life = data.dict("LifetimeData") {
            info.lifetime = BatteryLifetime(
                totalOperatingTime: life.int("TotalOperatingTime"),
                maximumTemperature: life.int("MaximumTemperature").map { Double($0) / 10 },
                minimumTemperature: life.int("MinimumTemperature").map { Double($0) / 10 },
                averageTemperature: life.int("AverageTemperature").map { Double($0) / 10 },
                maximumChargeCurrent: life.int("MaximumChargeCurrent"),
                maximumDischargeCurrent: life.int("MaximumDischargeCurrent"),
                maximumPackVoltage: life.int("MaximumPackVoltage"),
                minimumPackVoltage: life.int("MinimumPackVoltage")
            )
        }
        let manufacturerData = (props["ManufacturerData"] as? Data) ?? (data["MfgData"] as? Data)
        info.identity = BatteryIdentity(
            chemistryID: data.int("ChemID"),
            manufacturerStrings: manufacturerData.map(BatteryIdentity.strings) ?? [],
            dataFlashWriteCount: data.int("DataFlashWriteCount")
        )
        if let ports = props["PortControllerInfo"] as? [[String: Any]] {
            info.powerDelivery = PowerDeliveryInfo.parse(ports)
        }
        if info.externalConnected == true, let details = props.dict("AdapterDetails"), details["UsbHvcMenu"] != nil {
            var pd = info.powerDelivery ?? PowerDeliveryInfo(sourceCapabilities: [], contract: nil, capabilityMismatch: nil,
                                                             attachCount: nil, detachCount: nil, hardResetCount: nil, portIndex: 0)
            pd.applyAdapterDetails(details)
            info.powerDelivery = pd
        }
        info.gaugeStateOfCharge = data.int("StateOfCharge")
        info.permanentFailureStatus = props.int("PermanentFailureStatus")
        info.cellDisconnectCount = props.int("BatteryCellDisconnectCount")

        if let details = props.dict("AdapterDetails"), details.count > 1 || details.int("FamilyCode") != 0 {
            var adapter = AdapterInfo()
            adapter.ratedWatts = details.int("Watts")
            adapter.voltage = details.int("AdapterVoltage")
            adapter.current = details.int("Current")
            adapter.name = details.string("Name")
            adapter.manufacturer = details.string("Manufacturer")
            adapter.model = details.string("Model")
            adapter.description = details.string("Description")
            adapter.familyCode = details.int("FamilyCode")
            adapter.isWireless = details.bool("IsWireless")
            adapter.firmwareVersion = details.string("FwVersion")
            adapter.hardwareVersion = details.string("HwVersion")
            adapter.serial = details.string("SerialString").map { includeSerial ? $0 : Privacy.mask($0) }
            info.adapter = adapter
        }

        if let telemetry = props.dict("PowerTelemetryData") {
            info.powerTelemetry = PowerTelemetry(
                systemPowerIn: telemetry.int("SystemPowerIn"),
                systemVoltageIn: telemetry.int("SystemVoltageIn"),
                systemCurrentIn: telemetry.int("SystemCurrentIn"),
                systemLoad: telemetry.int("SystemLoad"),
                batteryPower: telemetry.int("BatteryPower"),
                adapterEfficiencyLoss: telemetry.int("AdapterEfficiencyLoss")
            )
        }

        if let battery = info.batteryPowerWatts {
            let telemetry = info.powerTelemetry
            if let input = telemetry?.systemPowerIn, input > 0, info.externalConnected == true {
                let loss = Double(telemetry?.adapterEfficiencyLoss ?? 0) / 1000
                info.systemPowerWatts = Double(input) / 1000 - battery - loss
            } else if info.externalConnected != true {
                info.systemPowerWatts = -battery
            }
        }

        if let charger = props.dict("ChargerData") {
            info.charger = ChargerInfo(
                chargingCurrent: charger.int("ChargingCurrent"),
                chargingVoltage: charger.int("ChargingVoltage"),
                notChargingReason: charger.int("NotChargingReason"),
                slowChargingReason: charger.int("SlowChargingReason"),
                chargerInhibitReason: charger.int("ChargerInhibitReason"),
                timeChargingThermallyLimited: charger.int("TimeChargingThermallyLimited"),
                vacVoltageLimit: charger.int("VacVoltageLimit")
            )
        }

        let serial = props.string("Serial") ?? props.string("BatterySerialNumber") ?? data.string("Serial")
        info.serial = serial.map { includeSerial ? $0 : Privacy.mask($0) }
        return info
    }
}
