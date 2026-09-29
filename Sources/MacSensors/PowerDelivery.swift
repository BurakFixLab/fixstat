import Foundation

/// A USB Power Delivery Power Data Object (source capability), decoded per the
/// USB PD 3.x specification.
public struct PowerDataObject: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case fixed, battery, variable, pps, unknown
    }

    public let kind: Kind
    /// Fixed: the voltage. Variable / battery / PPS: the maximum voltage. mV.
    public let maxVoltage: Int?
    /// Variable / battery / PPS: the minimum voltage. mV.
    public let minVoltage: Int?
    /// Maximum current in mA (not for battery PDOs).
    public let maxCurrent: Int?
    /// Battery PDOs: maximum power in mW.
    public let maxPower: Int?
    public let raw: UInt32

    public static func decode(_ raw: UInt32) -> PowerDataObject {
        func bits(_ high: Int, _ low: Int) -> Int {
            Int((raw >> UInt32(low)) & ((1 << UInt32(high - low + 1)) - 1))
        }
        switch raw >> 30 {
        case 0b00:
            return PowerDataObject(kind: .fixed, maxVoltage: bits(19, 10) * 50, minVoltage: nil,
                                   maxCurrent: bits(9, 0) * 10, maxPower: nil, raw: raw)
        case 0b01:
            return PowerDataObject(kind: .battery, maxVoltage: bits(29, 20) * 50, minVoltage: bits(19, 10) * 50,
                                   maxCurrent: nil, maxPower: bits(9, 0) * 250, raw: raw)
        case 0b10:
            return PowerDataObject(kind: .variable, maxVoltage: bits(29, 20) * 50, minVoltage: bits(19, 10) * 50,
                                   maxCurrent: bits(9, 0) * 10, maxPower: nil, raw: raw)
        default:
            // Augmented PDO; only SPR PPS (subtype 00) is decoded.
            guard bits(29, 28) == 0 else {
                return PowerDataObject(kind: .unknown, maxVoltage: nil, minVoltage: nil,
                                       maxCurrent: nil, maxPower: nil, raw: raw)
            }
            return PowerDataObject(kind: .pps, maxVoltage: bits(24, 17) * 100, minVoltage: bits(15, 8) * 100,
                                   maxCurrent: bits(6, 0) * 50, maxPower: nil, raw: raw)
        }
    }

    /// Power the object can deliver in mW (fixed / variable: V × I).
    public var power: Int? {
        if let maxPower { return maxPower }
        guard let v = maxVoltage, let i = maxCurrent else { return nil }
        return v * i / 1000
    }
}

/// The active USB PD contract (sink Request Data Object).
public struct PowerDeliveryContract: Codable, Sendable, Equatable {
    /// 1-based index into the source capabilities.
    public let objectPosition: Int
    /// The requested source capability, if known.
    public let sourceObject: PowerDataObject?
    /// Negotiated voltage in mV (fixed: the PDO voltage; PPS: the requested voltage).
    public let voltage: Int?
    /// Operating current requested by the Mac in mA.
    public let operatingCurrent: Int?
    /// Maximum current requested in mA (fixed / variable only).
    public let maxCurrent: Int?
    /// The sink reported that the source cannot cover its needs.
    public let capabilityMismatch: Bool
    public let raw: UInt32

    public static func decode(_ raw: UInt32, sourceCapabilities: [PowerDataObject]) -> PowerDeliveryContract {
        func bits(_ high: Int, _ low: Int) -> Int {
            Int((raw >> UInt32(low)) & ((1 << UInt32(high - low + 1)) - 1))
        }
        let position = bits(31, 28)
        let object = position >= 1 && position <= sourceCapabilities.count ? sourceCapabilities[position - 1] : nil
        let mismatch = bits(26, 26) == 1
        if object?.kind == .pps {
            return PowerDeliveryContract(objectPosition: position, sourceObject: object,
                                         voltage: bits(20, 9) * 20, operatingCurrent: bits(6, 0) * 50,
                                         maxCurrent: nil, capabilityMismatch: mismatch, raw: raw)
        }
        return PowerDeliveryContract(objectPosition: position, sourceObject: object,
                                     voltage: object?.maxVoltage, operatingCurrent: bits(19, 10) * 10,
                                     maxCurrent: bits(9, 0) * 10, capabilityMismatch: mismatch, raw: raw)
    }

    /// Negotiated power in mW (voltage × operating current).
    public var power: Int? {
        guard let voltage, let operatingCurrent else { return nil }
        return voltage * operatingCurrent / 1000
    }
}

/// USB-C port controller state (`PortControllerInfo`) of the port the Mac is charging from.
public struct PowerDeliveryInfo: Codable, Sendable, Equatable {
    /// What the connected source offers.
    public var sourceCapabilities: [PowerDataObject]
    public var contract: PowerDeliveryContract?
    /// Port controller flag: the source could not satisfy the sink's request.
    public var capabilityMismatch: Bool?
    public var attachCount: Int?
    public var detachCount: Int?
    public var hardResetCount: Int?
    /// 0-based index in `PortControllerInfo`.
    public var portIndex: Int
    /// Profiles the adapter offers as seen by macOS (`AdapterDetails.UsbHvcMenu`).
    public var adapterProfiles: [PowerDataObject] = []
    /// 0-based index of the profile macOS selected (`AdapterDetails.UsbHvcHvcIndex`).
    /// Authoritative for the active voltage; the port controller's request
    /// object does not always reflect Apple's high-voltage selection.
    public var adapterSelectedIndex: Int?

    /// The profile in use: macOS' selection if known, else the port controller's contract.
    public var activeProfile: PowerDataObject? {
        if let index = adapterSelectedIndex, adapterProfiles.indices.contains(index) {
            return adapterProfiles[index]
        }
        return contract?.sourceObject
    }

    /// 1-based position of the active profile in `offeredProfiles`.
    public var activePosition: Int? {
        if let index = adapterSelectedIndex, adapterProfiles.indices.contains(index) { return index + 1 }
        return contract?.objectPosition
    }

    /// What the adapter offers: macOS' list if known, else the port controller's.
    public var offeredProfiles: [PowerDataObject] {
        adapterProfiles.isEmpty ? sourceCapabilities : adapterProfiles
    }

    /// The port controller's request object when it agrees with the active profile.
    public var consistentContract: PowerDeliveryContract? {
        guard let contract else { return nil }
        guard let position = activePosition else { return contract }
        return contract.objectPosition == position ? contract : nil
    }

    /// Adds macOS' adapter profile list from `AdapterDetails`.
    mutating func applyAdapterDetails(_ details: [String: Any]) {
        if let menu = details["UsbHvcMenu"] as? [[String: Any]] {
            adapterProfiles = menu
                .sorted { ($0.int("Index") ?? 0) < ($1.int("Index") ?? 0) }
                .map { entry in
                    PowerDataObject(kind: .fixed, maxVoltage: entry.int("MaxVoltage"), minVoltage: nil,
                                    maxCurrent: entry.int("MaxCurrent"), maxPower: nil, raw: 0)
                }
        }
        adapterSelectedIndex = details.int("UsbHvcHvcIndex")
    }

    /// Picks the port with an active contract (or the first one) from the registry list.
    static func parse(_ ports: [[String: Any]]) -> PowerDeliveryInfo? {
        let indexed = Array(ports.enumerated())
        guard let (index, port) = indexed.first(where: { ($0.element.int("PortControllerActiveContractRdo") ?? 0) != 0 })
            ?? indexed.first else { return nil }
        let pdos = (port["PortControllerPortPDO"] as? [NSNumber] ?? [])
            .map { UInt32(truncatingIfNeeded: $0.int64Value) }
            .filter { $0 != 0 }
            .map(PowerDataObject.decode)
        let rdo = UInt32(truncatingIfNeeded: port.int("PortControllerActiveContractRdo") ?? 0)
        return PowerDeliveryInfo(
            sourceCapabilities: pdos,
            contract: rdo == 0 ? nil : .decode(rdo, sourceCapabilities: pdos),
            capabilityMismatch: port.int("PortControllerCapMismatch").map { $0 != 0 },
            attachCount: port.int("PortControllerAttachCount"),
            detachCount: port.int("PortControllerDetachCount"),
            hardResetCount: port.int("PortControllerHardResetCount"),
            portIndex: index
        )
    }
}
