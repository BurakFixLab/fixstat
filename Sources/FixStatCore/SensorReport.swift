import Foundation
import MacSensors

/// A sensor report for customer devices. Serial numbers are always masked.
public struct SensorReport: Encodable {
    struct Sensor: Encodable {
        let key: String
        let source: String
        let hidName: String?
        let id: String?
        let name: String
        let group: String?
        let confidence: String?
        let matchLevel: String?
        let celsius: Double?
    }

    struct Load: Encodable {
        let cpuUsagePercent: Double?
        let memoryUsedBytes: UInt64?
        let memoryTotalBytes: UInt64?
    }

    let app = "FixStat"
    let version = MacSensors.version
    let generatedAt: Date
    let system: SystemInfo
    let battery: BatteryInfo?
    let sensors: [Sensor]
    let fans: [FanReading]
    let load: Load
    /// Daily battery health recorded by FixStat on this Mac (oldest first).
    let healthHistory: [BatteryHealthRecord]
    let ssd: SSDInfo?
    let ssdTest: SSDStressTest.Result?
    let postRepairTest: StressTestResult?

    public init(monitor: MonitorCore) {
        generatedAt = Date()
        system = monitor.system
        // Re-read with masking enforced, independent of what the UI holds.
        battery = BatteryReader.read(includeSerial: false)
        sensors = monitor.sensors.map { sensor in
            Sensor(key: sensor.descriptor.rawLabel,
                   source: sensor.descriptor.source.rawValue,
                   hidName: sensor.descriptor.hidName,
                   id: sensor.resolved?.id,
                   name: sensor.name,
                   group: sensor.resolved?.group.rawValue,
                   confidence: sensor.resolved?.confidence.rawValue,
                   matchLevel: sensor.resolved?.level.rawValue,
                   celsius: monitor.value(of: sensor))
        }
        fans = monitor.fans
        load = Load(cpuUsagePercent: monitor.cpuUsage.map { $0 * 100 },
                    memoryUsedBytes: monitor.memory?.used,
                    memoryTotalBytes: monitor.memory?.total)
        healthHistory = monitor.history.healthRecords()
        ssd = SSDInfo.read(includeSerial: false)
        var ssdTest = monitor.lastSSDResult
        ssdTest?.timings = [] // per-block timings are too long for a report
        self.ssdTest = ssdTest
        postRepairTest = monitor.lastTestResult
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if #available(macOS 10.15, *) { encoder.outputFormatting.insert(.withoutEscapingSlashes) }
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// CSV with one row per value: section, key, name, value, unit.
    /// Column headers and units are technical identifiers, not UI text.
    public func csv() -> Data {
        var rows: [[String]] = [["section", "key", "name", "value", "unit"]]
        // Machine-readable numbers: POSIX, no grouping (same on every macOS version).
        let number = NumberFormatter()
        number.locale = Locale(identifier: "en_US_POSIX")
        number.numberStyle = .decimal
        number.usesGroupingSeparator = false
        number.maximumFractionDigits = 6
        func add(_ section: String, _ key: String, _ name: String, _ value: Double?, _ unit: String) {
            rows.append([section, key, name, value.flatMap { number.string(from: NSNumber(value: $0)) } ?? "", unit])
        }
        rows.append(["system", "model", system.model, "", ""])
        rows.append(["system", "marketingName", system.marketingName ?? "", "", ""])
        rows.append(["system", "board", system.boardTarget ?? "", "", ""])
        rows.append(["system", "chip", system.chip, "", ""])
        rows.append(["system", "macOS", system.osVersion, "", ""])
        rows.append(["system", "generatedAt", ISO8601DateFormatter().string(from: generatedAt), "", ""])
        if let b = battery {
            add("battery", "DesignCapacity", "", b.designCapacity.map(Double.init), "mAh")
            add("battery", "AppleRawMaxCapacity", "", b.rawMaxCapacity.map(Double.init), "mAh")
            add("battery", "NominalChargeCapacity", "", b.nominalChargeCapacity.map(Double.init), "mAh")
            add("battery", "health", "", b.healthPercent, "%")
            add("battery", "CycleCount", "", b.cycleCount.map(Double.init), "")
            add("battery", "Temperature", "", b.temperature, "°C")
            add("battery", "Voltage", "", b.voltage.map(Double.init), "mV")
            add("battery", "Amperage", "", b.amperage.map(Double.init), "mA")
            for (index, cell) in (b.cellVoltages ?? []).enumerated() {
                add("battery", "CellVoltage\(index + 1)", "", Double(cell), "mV")
            }
            add("battery", "cellImbalance", "", b.cellImbalance.map(Double.init), "mV")
            for (index, value) in (b.cellQmax ?? []).enumerated() {
                add("battery", "Qmax\(index + 1)", "", Double(value), "mAh")
            }
            for (index, value) in (b.cellResistance ?? []).enumerated() {
                add("battery", "WeightedRa\(index + 1)", "", Double(value), "")
            }
            add("battery", "ChemID", b.identity?.manufacturerStrings.joined(separator: " ") ?? "",
                b.identity?.chemistryID.map(Double.init), "")
            if let l = b.lifetime {
                add("lifetime", "TotalOperatingTime", "", l.totalOperatingTime.map(Double.init), "h")
                add("lifetime", "MaximumTemperature", "", l.maximumTemperature, "°C")
                add("lifetime", "MinimumTemperature", "", l.minimumTemperature, "°C")
                add("lifetime", "MaximumChargeCurrent", "", l.maximumChargeCurrent.map(Double.init), "mA")
                add("lifetime", "MaximumDischargeCurrent", "", l.maximumDischargeCurrent.map(Double.init), "mA")
            }
            if let c = b.powerDelivery?.contract {
                add("usbpd", "ContractVoltage", "profile \(c.objectPosition)", c.voltage.map(Double.init), "mV")
                add("usbpd", "ContractCurrent", "", c.operatingCurrent.map(Double.init), "mA")
            }
            for (index, pdo) in (b.powerDelivery?.sourceCapabilities ?? []).enumerated() {
                add("usbpd", "SourcePDO\(index + 1)", pdo.kind.rawValue, pdo.maxVoltage.map(Double.init), "mV")
            }
            add("battery", "SystemPowerIn", "", b.powerTelemetry?.systemPowerIn.map(Double.init), "mW")
            add("battery", "AdapterWatts", b.adapter?.name ?? "", b.adapter?.ratedWatts.map(Double.init), "W")
            rows.append(["battery", "Serial", b.serial ?? "", "", ""])
        }
        for sensor in sensors {
            add("sensor", sensor.key, sensor.name, sensor.celsius, "°C")
        }
        for fan in fans {
            add("fan", "F\(fan.index)Ac", "", fan.actual, "rpm")
        }
        for record in healthHistory {
            add("healthHistory", record.day, record.cycleCount.map { "cycles \($0)" } ?? "", record.health, "%")
        }
        if let h = ssd?.health {
            add("ssd", "percentageUsed", ssd?.model ?? "", Double(h.percentageUsed), "%")
            add("ssd", "availableSpare", "", Double(h.availableSpare), "%")
            add("ssd", "bytesWritten", "", h.bytesWritten, "B")
            add("ssd", "powerOnHours", "", h.powerOnHours, "h")
            add("ssd", "unsafeShutdowns", "", h.unsafeShutdowns, "")
            add("ssd", "mediaErrors", "", h.mediaErrors, "")
        }
        add("load", "cpu", "", load.cpuUsagePercent, "%")
        add("load", "memoryUsed", "", load.memoryUsedBytes.map(Double.init), "B")
        let text = rows.map { $0.map(Self.escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
        return Data(text.utf8)
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { ",\"\n".contains($0) }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "FixStat-MacBookAir10,1-2026-09-30.pdf"
    public static func fileName(model: String, fileExtension: String, now: Date = Date()) -> String {
        "FixStat-\(model)-\(Format.isoDay(now)).\(fileExtension)"
    }
}
