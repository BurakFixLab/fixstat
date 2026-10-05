import Foundation

/// Reference values of known-genuine parts (`SensorMaps/parts.json`).
public struct PartsReference: Codable, Sendable, Equatable {
    public struct Battery: Codable, Sendable, Equatable {
        public var designCapacity: [Int]
        public var chemistryIDs: [Int]
        public var gauges: [String]
        public var cellCount: Int?
        public var cellVendors: [String]
        public var samples: Int?
    }

    public struct Adapter: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var manufacturer: String?
        public var watts: Int?
        /// [mV, mA] pairs.
        public var profiles: [[Int]]?
        public var firmware: [String]?
        public var samples: Int?
    }

    public var schemaVersion: Int
    /// Free-text note at the top of parts.json (kept when the file is rewritten).
    public var note: String?
    public var batteries: [String: Battery]
    public var adapters: [Adapter]

    public init(batteries: [String: Battery] = [:], adapters: [Adapter] = []) {
        schemaVersion = 1
        self.batteries = batteries
        self.adapters = adapters
    }

    public static func load(from url: URL) throws -> PartsReference {
        try JSONDecoder().decode(PartsReference.self, from: Data(contentsOf: url))
    }
}

/// Health as reported by macOS (System Information).
public struct MacOSBatteryHealth: Codable, Sendable, Equatable {
    /// e.g. "Good", "Check Battery", "Service Recommended".
    public var condition: String?
    /// e.g. "78%".
    public var maximumCapacity: String?

    /// Runs `system_profiler SPPowerDataType -json` (about a second).
    public static func read() -> MacOSBatteryHealth? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(data)
    }

    static func parse(_ data: Data) -> MacOSBatteryHealth? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let battery = items.first(where: { ($0["_name"] as? String) == "spbattery_information" }),
              let health = battery["sppower_battery_health_info"] as? [String: Any] else { return nil }
        return MacOSBatteryHealth(condition: health["sppower_battery_health"] as? String,
                                  maximumCapacity: health["sppower_battery_health_maximum_capacity"] as? String)
    }

    /// True for "Good" / "Normal".
    public var isGood: Bool {
        guard let condition else { return false }
        return ["good", "normal"].contains(condition.lowercased())
    }
}

/// Evidence-based originality check for the battery and the power adapter.
///
/// macOS offers no "genuine part" flag for Mac batteries, and a clone can copy
/// every digital field; the result is therefore "consistent with genuine",
/// "suspicious" or "not enough reference data", with the evidence listed.
public struct PartCheck: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable {
        case consistent, suspicious, unknown
    }

    public enum Status: String, Codable, Sendable {
        case pass, warn, info
    }

    public struct Item: Codable, Sendable, Equatable {
        /// Stable id, used as localization key by the app.
        public let id: String
        public let status: Status
        /// Values involved (not localized), e.g. "bq20z451" or "4382 / 4382".
        public let detail: String
    }

    public let verdict: Verdict
    public let items: [Item]

    static func verdict(for items: [Item]) -> Verdict {
        if items.contains(where: { $0.status == .warn }) { return .suspicious }
        // Reference-based evidence (not just "data present") is needed for a positive verdict.
        let referencePasses = items.filter { $0.status == .pass && $0.id.hasPrefix("ref.") }.count
        return referencePasses >= 2 ? .consistent : .unknown
    }

    // MARK: Battery

    public static func battery(_ b: BatteryInfo, model: String, reference: PartsReference) -> PartCheck {
        var items: [Item] = []
        let ref = reference.batteries[model]
        let gauge = b.gaugeDeviceName ?? ""

        if let ref {
            // An empty list means no reference value was recorded: no check.
            if !ref.gauges.isEmpty {
                items.append(Item(id: "ref.gauge", status: ref.gauges.contains(gauge) ? .pass : .warn, detail: gauge))
            }
            if let chem = b.identity?.chemistryID, !ref.chemistryIDs.isEmpty {
                items.append(Item(id: "ref.chemistry", status: ref.chemistryIDs.contains(chem) ? .pass : .warn,
                                  detail: String(chem)))
            }
            if let design = b.designCapacity, !ref.designCapacity.isEmpty {
                let ok = ref.designCapacity.contains { abs($0 - design) <= max(1, $0 / 100) }
                items.append(Item(id: "ref.designCapacity", status: ok ? .pass : .warn,
                                  detail: "\(design) / \(ref.designCapacity.map(String.init).joined(separator: ", ")) mAh"))
            }
            if let cells = b.cellVoltages?.count, let expected = ref.cellCount {
                items.append(Item(id: "ref.cellCount", status: cells == expected ? .pass : .warn, detail: "\(cells) / \(expected)"))
            }
            if let vendor = b.identity?.manufacturerStrings.last {
                items.append(Item(id: "ref.cellVendor", status: ref.cellVendors.contains(vendor) ? .pass : .info, detail: vendor))
            }
        } else {
            items.append(Item(id: "noReference", status: .info, detail: model))
            items.append(Item(id: "gauge", status: gauge.lowercased().hasPrefix("bq") ? .info : .warn, detail: gauge))
        }

        let strings = b.identity?.manufacturerStrings ?? []
        items.append(Item(id: "manufacturerData", status: strings.isEmpty ? .warn : .pass,
                          detail: strings.joined(separator: " · ")))
        let learned = (b.cellQmax?.isEmpty == false) && (b.cellResistance?.isEmpty == false) && b.lifetime != nil
        items.append(Item(id: "gaugeData", status: learned ? .pass : .warn, detail: ""))
        let serialLength = b.serial?.count ?? 0
        items.append(Item(id: "serial", status: serialLength >= 10 ? .pass : .warn, detail: ""))
        if let cycles = b.cycleCount, let hours = b.lifetime?.totalOperatingTime, cycles < 5, hours > 500 {
            items.append(Item(id: "cycleReset", status: .warn, detail: "\(cycles) / \(hours) h"))
        }
        return PartCheck(verdict: verdict(for: items), items: items)
    }

    // MARK: Adapter

    /// nil when no adapter details are available (not connected / not reported).
    public static func adapter(_ b: BatteryInfo, reference: PartsReference) -> PartCheck? {
        guard b.externalConnected == true, let adapter = b.adapter, adapter.name != nil || adapter.manufacturer != nil else {
            return nil
        }
        var items: [Item] = []
        let manufacturer = adapter.manufacturer ?? ""
        items.append(Item(id: "adapter.manufacturer", status: manufacturer == "Apple Inc." ? .pass : .warn, detail: manufacturer))

        let name = adapter.name ?? ""
        if let nameWatts = Int(name.prefix { $0.isNumber }), let watts = adapter.ratedWatts {
            let ok = watts <= nameWatts && watts >= nameWatts - 6
            items.append(Item(id: "adapter.nameWatts", status: ok ? .pass : .warn, detail: "\(name) · \(watts) W"))
        }
        items.append(Item(id: "adapter.serial", status: (adapter.serial?.count ?? 0) >= 8 ? .pass : .warn, detail: ""))

        let id = adapter.model ?? ""
        if let ref = reference.adapters.first(where: { $0.id.lowercased() == id.lowercased() }) {
            items.append(Item(id: "ref.adapter.id", status: ref.name == name ? .pass : .warn, detail: "\(id) · \(ref.name)"))
            if let firmware = ref.firmware, let current = adapter.firmwareVersion {
                items.append(Item(id: "ref.adapter.firmware", status: firmware.contains(current) ? .pass : .info, detail: current))
            }
            if let profiles = ref.profiles, let offered = b.powerDelivery?.offeredProfiles, !offered.isEmpty {
                let actual = offered.map { [$0.maxVoltage ?? 0, $0.maxCurrent ?? 0] }
                items.append(Item(id: "ref.adapter.profiles", status: actual == profiles ? .pass : .warn,
                                  detail: actual.map { "\($0[0] / 1000)V \(Double($0[1]) / 1000)A" }.joined(separator: ", ")))
            }
        } else {
            items.append(Item(id: "adapter.noReference", status: .info, detail: id.isEmpty ? name : "\(id) · \(name)"))
        }
        return PartCheck(verdict: verdict(for: items), items: items)
    }
}
