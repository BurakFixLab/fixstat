import Foundation
import MacSensors

// sensordump — prints battery, temperature and fan data of this Mac.
// Read-only: nothing is ever written to the SMC. No root privileges needed.

let usage = """
    usage: sensordump [options]

      --json            Output JSON instead of tables
      --include-serial  Show serial numbers unmasked (masked by default)
      --raw             Include all raw AppleSmartBattery registry properties
      --smc-all         Include every SMC key with its decoded value
      --hid-power       Include HID voltage/current sensors (raw, experimental)
      --all             Also list SMC temperature keys with implausible values
      -h, --help        Show this help
    """

var options = MacSensors.Options()
var jsonOutput = false
var showAllTemperatures = false

for argument in CommandLine.arguments.dropFirst() {
    switch argument {
    case "--json": jsonOutput = true
    case "--include-serial": options.includeSerial = true
    case "--raw": options.includeRawBattery = true
    case "--smc-all": options.includeAllSMCKeys = true
    case "--hid-power": options.includeHIDPower = true
    case "--all": showAllTemperatures = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        FileHandle.standardError.write(Data("sensordump: unknown option \(argument)\n\n\(usage)\n".utf8))
        exit(2)
    }
}

let snapshot = MacSensors.snapshot(options: options)

if jsonOutput {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
    let data = try encoder.encode(snapshot)
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}

// MARK: - Text output

func fmt(_ value: Double?, _ digits: Int = 1, unit: String = "") -> String {
    guard let value else { return "-" }
    return String(format: "%.\(digits)f", value) + unit
}

func fmt(_ value: Int?, unit: String = "") -> String {
    guard let value else { return "-" }
    return "\(value)" + unit
}

func signed(_ value: Int?, unit: String) -> String {
    guard let value else { return "-" }
    return (value > 0 ? "+" : "") + "\(value)" + unit
}

func minutes(_ value: Int?) -> String {
    guard let value else { return "-" }
    return value >= 60 ? "\(value / 60) h \(value % 60) min" : "\(value) min"
}

func section(_ title: String) {
    print("\n\(title)")
}

func keyValues(_ pairs: [(String, String)]) {
    let width = pairs.map(\.0.count).max() ?? 0
    for (key, value) in pairs {
        print("  " + key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + value)
    }
}

let system = snapshot.system
print("sensordump \(snapshot.version)")
keyValues([
    ("Model", system.model + (system.boardTarget.map { " (\($0))" } ?? "")),
    ("Chip", "\(system.chip) · \(system.architecture)"),
    ("macOS", system.osVersion),
])

if let b = snapshot.battery {
    section("BATTERY")
    let state: String
    if b.fullyCharged == true {
        state = "Fully charged"
    } else if b.isCharging == true {
        state = "Charging"
    } else if b.externalConnected == true {
        state = "On AC, not charging"
    } else {
        state = "Discharging"
    }
    var pairs: [(String, String)] = [
        ("Gauge", b.gaugeDeviceName ?? "-"),
        ("State", "\(state), \(fmt(b.stateOfCharge, 0, unit: " %")) (gauge SOC \(fmt(b.gaugeStateOfCharge, unit: " %")))"),
        ("Health (raw max)", "\(fmt(b.healthPercent, 1, unit: " %"))  = AppleRawMaxCapacity \(fmt(b.rawMaxCapacity)) / DesignCapacity \(fmt(b.designCapacity, unit: " mAh"))"),
        ("Health (nominal)", "\(fmt(b.nominalHealthPercent, 1, unit: " %"))  = NominalChargeCapacity \(fmt(b.nominalChargeCapacity, unit: " mAh"))"),
        ("Remaining capacity", fmt(b.rawCurrentCapacity, unit: " mAh")),
        ("Cycle count", "\(fmt(b.cycleCount)) / \(fmt(b.designCycleCount)) design"),
        ("Temperature", "\(fmt(b.temperature, 2, unit: " °C")) (virtual \(fmt(b.virtualTemperature, 2, unit: " °C")))"),
        ("Voltage", fmt(b.voltage, unit: " mV")),
        ("Amperage", "\(signed(b.amperage, unit: " mA")) (instant \(signed(b.instantAmperage, unit: " mA")))"),
        ("Battery power", fmt(b.batteryPowerWatts, 2, unit: " W")),
    ]
    if b.isCharging == true {
        pairs.append(("Time to full", minutes(b.timeToFull)))
    } else if b.externalConnected != true {
        pairs.append(("Time to empty", minutes(b.timeToEmpty ?? b.timeRemaining)))
    }
    if let cells = b.cellVoltages {
        let list = cells.enumerated().map { "\($0.offset + 1): \($0.element) mV" }.joined(separator: "  ")
        pairs.append(("Cell voltages", list))
        pairs.append(("Cell imbalance", fmt(b.cellImbalance, unit: " mV")))
    }
    if let qmax = b.cellQmax {
        pairs.append(("Cell Qmax", qmax.map { "\($0)" }.joined(separator: " / ") + " mAh"))
    }
    if let resistance = b.cellResistance {
        pairs.append(("Cell resistance", resistance.map { "\($0)" }.joined(separator: " / ") + " (WeightedRa, gauge units)"))
    }
    if CellAnalysis(battery: b).defaultQmax {
        pairs.append(("Cell Qmax note", "every Qmax equals the design capacity: gauge defaults, not learned"))
    }
    for cell in CellAnalysis(battery: b).suspects {
        var notes: [String] = []
        if cell.lowVoltage, let v = cell.voltage { notes.append("\(v) mV, below \(CellAnalysis.minimumVoltage) mV (over-discharged)") }
        if cell.highResistance, let d = cell.resistanceDeviation {
            notes.append(String(format: "resistance %+.0f %% vs. pack average", d * 100))
        }
        if cell.lowCapacity, let d = cell.qmaxDeviation { notes.append(String(format: "Qmax %+.0f %% vs. pack average", d * 100)) }
        pairs.append(("Suspect cell", "\(cell.number): " + notes.joined(separator: ", ")))
    }
    if let id = b.identity {
        pairs.append(("Chemistry ID", fmt(id.chemistryID)))
        pairs.append(("Manufacturer data", id.manufacturerStrings.isEmpty ? "-" : id.manufacturerStrings.joined(separator: " · ")))
    }
    pairs.append(("Permanent failure", fmt(b.permanentFailureStatus)))
    pairs.append(("Cell disconnects", fmt(b.cellDisconnectCount)))
    pairs.append(("Serial", b.serial ?? "-"))
    keyValues(pairs)

    section("POWER INPUT")
    var power: [(String, String)] = [
        ("External power", b.externalConnected == true ? "connected" : "not connected"),
        ("System power", fmt(b.systemPowerWatts, 2, unit: " W") + " (derived: input − battery V×I − adapter loss)"),
    ]
    if let a = b.adapter {
        power += [
            ("Adapter", [a.manufacturer, a.name, a.description].compactMap { $0 }.joined(separator: " · ")),
            ("Adapter rating", "\(fmt(a.ratedWatts, unit: " W")) (\(fmt(a.voltage, unit: " mV")), \(fmt(a.current, unit: " mA")))"),
            ("Adapter serial", a.serial ?? "-"),
        ]
    }
    if let t = b.powerTelemetry {
        power += [
            ("Input power", fmt(t.systemPowerIn.map { Double($0) / 1000 }, 2, unit: " W")
                + " (\(fmt(t.systemVoltageIn, unit: " mV")), \(fmt(t.systemCurrentIn, unit: " mA")))"),
            ("SystemLoad (raw)", fmt(t.systemLoad, unit: " mW")),
            ("Adapter loss", fmt(t.adapterEfficiencyLoss.map { Double($0) / 1000 }, 2, unit: " W")),
        ]
    }
    if let c = b.charger {
        power += [
            ("Charging current", fmt(c.chargingCurrent, unit: " mA")),
            ("Charging voltage", fmt(c.chargingVoltage, unit: " mV")),
            ("NotChargingReason", fmt(c.notChargingReason)),
            ("SlowChargingReason", fmt(c.slowChargingReason)),
            ("ChargerInhibitReason", fmt(c.chargerInhibitReason)),
        ]
    }
    keyValues(power)

    if let l = b.lifetime {
        section("LIFETIME (gauge)")
        keyValues([
            ("Operating time", fmt(l.totalOperatingTime, unit: " h")),
            ("Temperature", "\(fmt(l.minimumTemperature, 1)) … \(fmt(l.maximumTemperature, 1)) °C (avg \(fmt(l.averageTemperature, 1)))"),
            ("Max charge current", fmt(l.maximumChargeCurrent, unit: " mA")),
            ("Max discharge current", fmt(l.maximumDischargeCurrent, unit: " mA")),
            ("Pack voltage", "\(fmt(l.minimumPackVoltage)) … \(fmt(l.maximumPackVoltage, unit: " mV"))"),
        ])
    }

    if let pd = b.powerDelivery {
        section("USB-C POWER DELIVERY" + (b.externalConnected == true ? "" : " (last contract, adapter not connected)"))
        var rows: [(String, String)] = []
        if let active = pd.activeProfile {
            rows.append(("Active profile", "\(pd.activePosition.map { "profile \($0): " } ?? "")\(fmt(active.maxVoltage, unit: " mV")) \(fmt(active.maxCurrent, unit: " mA"))"
                + (pd.adapterSelectedIndex != nil ? " (macOS selection)" : " (port controller)")))
        }
        if let c = pd.contract {
            rows.append(("Port controller RDO", "profile \(c.objectPosition), requested \(fmt(c.operatingCurrent, unit: " mA"))"
                + (c.capabilityMismatch ? " — capability mismatch" : "") + (pd.consistentContract == nil ? " (differs from macOS selection)" : "")))
        }
        for (i, pdo) in pd.offeredProfiles.enumerated() {
            let range = pdo.minVoltage.map { "\($0)–" } ?? ""
            rows.append(("Source PDO \(i + 1)", "\(pdo.kind.rawValue) \(range)\(fmt(pdo.maxVoltage, unit: " mV")) \(fmt(pdo.maxCurrent, unit: " mA"))"))
        }
        rows.append(("Attach / detach", "\(fmt(pd.attachCount)) / \(fmt(pd.detachCount))"))
        rows.append(("Hard resets", fmt(pd.hardResetCount)))
        keyValues(rows)
    }
} else {
    section("BATTERY")
    print("  no AppleSmartBattery found")
}

if let ssd = snapshot.ssd {
    section("SSD")
    var rows: [(String, String)] = [
        ("Model", ssd.model ?? "-"),
        ("Firmware", ssd.firmware ?? "-"),
        ("Capacity", ssd.capacity.map { String(format: "%.0f GB", $0 / 1e9) } ?? "-"),
        ("NAND", [ssd.nandVendor, ssd.nandType, ssd.bitsPerCell.map { "\($0) bits/cell" }].compactMap { $0 }.joined(separator: " · ")),
        ("Serial", ssd.serial ?? "-"),
        ("Interconnect", ssd.interconnect ?? "-"),
        ("Health", ssd.healthPercent.map { "\($0) %" } ?? "-"),
        ("Startup volume", ssd.space.map { String(format: "%.0f of %.0f GB used, %.0f GB free", $0.used / 1e9, $0.total / 1e9, $0.available / 1e9) } ?? "-"),
    ]
    if let a = ssd.ata {
        rows += [
            ("ATA SMART", a.thresholdExceeded == true ? "FAILING (threshold exceeded)" : "ok"),
            ("Life left", a.lifeLeft.map { "\($0.percent) % (attribute \($0.attribute))" } ?? "-"),
        ]
        for attribute in a.attributes {
            rows.append((String(format: "  #%d", attribute.id),
                         "value \(attribute.current) worst \(attribute.worst) threshold \(attribute.threshold) raw \(attribute.raw)"))
        }
    }
    for drive in ssd.otherDrives {
        rows.append(("Other drive", [drive.model, drive.medium, drive.capacity.map { String(format: "%.0f GB", $0 / 1e9) },
                                     drive.health.map { $0.thresholdExceeded == true ? "SMART FAILING" : "SMART ok" }]
            .compactMap { $0 }.joined(separator: " · ")))
    }
    if let h = ssd.health {
        rows += [
            ("Percentage used", "\(h.percentageUsed) %"),
            ("Available spare", "\(h.availableSpare) % (threshold \(h.availableSpareThreshold) %)"),
            ("Data written", String(format: "%.2f TB", h.bytesWritten / 1e12)),
            ("Data read", String(format: "%.2f TB", h.bytesRead / 1e12)),
            ("Power-on hours", String(format: "%.0f", h.powerOnHours)),
            ("Power cycles", String(format: "%.0f", h.powerCycles)),
            ("Unsafe shutdowns", String(format: "%.0f", h.unsafeShutdowns)),
            ("Media errors", String(format: "%.0f", h.mediaErrors)),
            ("Error log entries", String(format: "%.0f", h.errorLogEntries)),
            ("Temperature", fmt(h.temperature, 0, unit: " °C")),
            ("Critical warning", h.criticalWarning == 0 ? "none" : h.warnings.joined(separator: ", ")),
        ]
    } else if ssd.ata == nil {
        rows.append(("SMART", "not available" + (ssd.smartProblem.map { ": \($0)" } ?? "")))
    }
    keyValues(rows)
}

section("HID TEMPERATURES (\(snapshot.hidTemperatures.count))")
if snapshot.hidTemperatures.isEmpty {
    print("  none")
} else {
    var table = TextTable(["Name", "Key", "°C", ""], alignments: [.left, .left, .right, .left])
    for r in snapshot.hidTemperatures {
        let note = SMC.plausibleTemperatureRange.contains(r.value) ? "" : "implausible (open sensor?)"
        table.add([r.name, r.key ?? "", fmt(r.value, 1), note])
    }
    print(table.render())
}

let plausible = SMC.plausibleTemperatureRange
let smcTemps = snapshot.smcTemperatures.filter { showAllTemperatures || plausible.contains($0.value ?? -1) }
let hidden = snapshot.smcTemperatures.count - smcTemps.count
section("SMC TEMPERATURES (\(smcTemps.count)" + (hidden > 0 ? ", \(hidden) implausible hidden, use --all" : "") + ")")
if smcTemps.isEmpty {
    print("  none")
} else {
    var table = TextTable(["Key", "Type", "°C"], alignments: [.left, .left, .right])
    for r in smcTemps { table.add([r.key, r.type, fmt(r.value, 1)]) }
    print(table.render())
}

section("FANS (\(snapshot.fans.count))")
if snapshot.fans.isEmpty {
    print("  none reported by SMC (FNum = 0 or missing)")
} else {
    var table = TextTable(["Fan", "Actual", "Target", "Min", "Max"], alignments: [.left, .right, .right, .right, .right])
    for f in snapshot.fans {
        table.add(["F\(f.index)", fmt(f.actual, 0), fmt(f.target, 0), fmt(f.minimum, 0), fmt(f.maximum, 0)])
    }
    print(table.render())
}

let ports = PortReader.read()
section("PORTS (\(ports.count))")
if ports.isEmpty {
    print("  none published (IOPort)")
} else {
    var table = TextTable(["Port", "Connected", "Transports", "Power in", "Overcurrent", "Enum. fail", "Short det.",
                           "PD hard reset", "FET fail", "I2C err", "Plug-ins"],
                          alignments: [.left, .left, .left, .left, .right, .right, .right, .right, .right, .right, .right])
    for p in ports {
        let c = p.controller
        table.add([p.id, p.connected ? "yes" : "no", p.activeTransports.joined(separator: ","),
                   p.powerIn.map { $0 ? "yes" : "no" } ?? "", fmt(p.overcurrentCount), fmt(p.enumerationFailures),
                   fmt(c?.shortDetect), fmt(c?.hardReset), fmt(c?.inputFETFailures), fmt(c?.i2cErrors),
                   fmt(p.connectionCount)])
    }
    print(table.render())
    for p in ports {
        for d in p.devices {
            print("  \(p.id): \(d.name ?? "USB device")" + (d.megabitsPerSecond.map { " (\($0) Mb/s)" } ?? ""))
        }
    }
}

if let voltages = snapshot.hidVoltages, let currents = snapshot.hidCurrents {
    section("HID POWER SENSORS — raw event values, units unverified (\(voltages.count) voltage, \(currents.count) current)")
    var table = TextTable(["Name", "Key", "Kind", "Raw value"], alignments: [.left, .left, .left, .right])
    for r in voltages { table.add([r.name, r.key ?? "", "voltage", fmt(r.value, 3)]) }
    for r in currents { table.add([r.name, r.key ?? "", "current", fmt(r.value, 3)]) }
    print(table.render())
}

if let all = snapshot.smcAllKeys {
    section("ALL SMC KEYS (\(all.count))")
    var table = TextTable(["Key", "Type", "Value", "Hex"], alignments: [.left, .left, .right, .left])
    for r in all { table.add([r.key, r.type, r.value.map { String(format: "%g", $0) } ?? "", r.hex]) }
    print(table.render())
}

if let raw = snapshot.batteryRaw {
    section("RAW AppleSmartBattery (serials masked unless --include-serial)")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(raw), as: UTF8.self))
}

if !snapshot.errors.isEmpty {
    section("ERRORS")
    for error in snapshot.errors { print("  \(error)") }
}
