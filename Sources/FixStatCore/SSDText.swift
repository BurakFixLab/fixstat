import Foundation
import MacSensors

/// Localized SSD texts (window and PDF report).
public enum SSDText {
    public static let usedWarning = 80
    public static let usedCritical = 100

    public static func healthFindings(_ h: NVMeHealth) -> [String] {
        var findings: [String] = []
        if h.criticalWarning != 0 {
            findings.append(L("The SSD reports a critical warning (code %lld).", h.criticalWarning))
        }
        if h.percentageUsed >= usedCritical {
            findings.append(L("Rated endurance used up (%lld %%).", h.percentageUsed))
        } else if h.percentageUsed >= usedWarning {
            findings.append(L("Most of the rated endurance is used (%lld %%).", h.percentageUsed))
        }
        if h.availableSpare < h.availableSpareThreshold {
            findings.append(L("Spare blocks below threshold (%lld %%).", h.availableSpare))
        }
        if h.mediaErrors > 0 {
            findings.append(L("%@ media / data integrity errors recorded.", Format.number(h.mediaErrors)))
        }
        return findings
    }

    public static func healthRows(_ h: NVMeHealth) -> [(String, String)] {
        [
            (L("Endurance used"), Format.percent(Double(h.percentageUsed))),
            (L("Available spare"), Format.percent(Double(h.availableSpare))),
            (L("Data written"), Format.bytes(h.bytesWritten)),
            (L("Data read"), Format.bytes(h.bytesRead)),
            (L("Power-on hours"), Format.number(h.powerOnHours)),
            (L("Power cycles"), Format.number(h.powerCycles)),
            (L("Unsafe shutdowns"), Format.number(h.unsafeShutdowns)),
            (L("Media errors"), Format.number(h.mediaErrors)),
            (L("Error log entries"), Format.number(h.errorLogEntries)),
            (L("Temperature"), h.temperature.map { Format.temperature($0, digits: 0) } ?? "–"),
        ]
    }

    /// "Health 97 %" with what it is based on.
    public static func healthSummary(_ info: SSDInfo) -> String? {
        guard let percent = info.healthPercent else { return nil }
        if let health = info.health {
            return L("Health %@ (%@ of the rated endurance used)", Format.percent(Double(percent)),
                     Format.percent(Double(health.percentageUsed)))
        }
        if let attribute = info.ata?.lifeLeft?.attribute {
            return L("Health %@ (SMART attribute %lld, vendor estimate)", Format.percent(Double(percent)), attribute)
        }
        return nil
    }

    /// "162 GB used of 245 GB · 83 GB free" (startup volume).
    public static func space(_ space: VolumeSpace) -> String {
        L("%@ used of %@ · %@ free", Format.bytes(space.used), Format.bytes(space.total), Format.bytes(space.available))
    }

    /// Model line: capacity, NAND, interconnect, firmware.
    public static func identity(_ info: SSDInfo) -> String {
        [info.capacity.map { Format.bytes($0) },
         [info.nandVendor, info.nandType].compactMap { $0 }.joined(separator: " "),
         info.bitsPerCell.map { L("%lld bits per cell", $0) },
         info.interconnect.map(interconnect),
         info.firmware.map { "FW \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    static func interconnect(_ name: String) -> String {
        switch name {
        case "PCI-Express": return "PCIe"
        case "Apple Fabric": return "Apple Fabric"
        default: return name
        }
    }

    // MARK: ATA / SATA SMART

    public static let lifeLeftWarning = 20

    public static func ataFindings(_ h: ATAHealth) -> [String] {
        var findings: [String] = []
        if h.thresholdExceeded == true {
            findings.append(L("The drive reports a SMART failure (threshold exceeded)."))
        }
        for attribute in h.failingAttributes {
            findings.append(L("Attribute %lld (%@) is below its failure threshold.", attribute.id, attributeName(attribute.id)))
        }
        if let life = h.lifeLeft, life.percent <= lifeLeftWarning {
            findings.append(L("Little rated endurance left (%@).", Format.percent(Double(life.percent))))
        }
        if let count = h.reallocatedSectors, count > 0 {
            findings.append(L("%@ reallocated sectors: the drive has replaced failing blocks.", Format.number(count)))
        }
        if let count = h.pendingSectors, count > 0 {
            findings.append(L("%@ sectors waiting for reallocation: unreadable blocks right now.", Format.number(count)))
        }
        if let count = h.uncorrectableSectors, count > 0 {
            findings.append(L("%@ uncorrectable sectors.", Format.number(count)))
        }
        if let count = h.crcErrors, count > 0 {
            findings.append(L("%@ interface CRC errors: check the SATA cable / flex and the connector.", Format.number(count)))
        }
        return findings
    }

    public static func ataRows(_ h: ATAHealth) -> [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ title: String, _ value: Double?) {
            if let value { rows.append((title, Format.number(value))) }
        }
        if let life = h.lifeLeft { rows.append((L("Life left"), Format.percent(Double(life.percent)))) }
        add(L("Power-on hours"), h.powerOnHours)
        add(L("Power cycles"), h.powerCycles)
        add(L("Unsafe shutdowns"), h.unsafeShutdowns)
        add(L("Reallocated sectors"), h.reallocatedSectors)
        add(L("Pending sectors"), h.pendingSectors)
        add(L("Uncorrectable sectors"), h.uncorrectableSectors)
        add(L("Interface CRC errors"), h.crcErrors)
        if let written = h.bytesWritten { rows.append((L("Data written (estimate)"), Format.bytes(written))) }
        if let temperature = h.temperature { rows.append((L("Temperature"), Format.temperature(temperature, digits: 0))) }
        return rows
    }

    /// All attributes: id, name, current, worst, threshold, raw.
    public static func ataTable(_ h: ATAHealth) -> [[String]] {
        h.attributes.map { a in
            [String(a.id), attributeName(a.id), String(a.current), String(a.worst),
             a.threshold > 0 ? String(a.threshold) : "–", String(a.raw)]
        }
    }

    public static var ataTableHeader: [String] {
        [L("ID"), L("Attribute"), L("Value"), L("Worst"), L("Threshold"), L("Raw")]
    }

    public static func attributeName(_ id: Int) -> String {
        switch id {
        case 1: return L("Read error rate")
        case 5: return L("Reallocated sectors")
        case 9: return L("Power-on hours")
        case 12: return L("Power cycles")
        case 169: return L("Remaining life")
        case 171: return L("Program fails")
        case 172: return L("Erase fails")
        case 173: return L("Wear leveling")
        case 174: return L("Unexpected power losses")
        case 177: return L("Wear leveling count")
        case 179: return L("Used reserved blocks")
        case 181: return L("Program fails")
        case 182: return L("Erase fails")
        case 187: return L("Reported uncorrectable errors")
        case 192: return L("Unsafe shutdowns")
        case 194: return L("Temperature")
        case 196: return L("Reallocation events")
        case 197: return L("Pending sectors")
        case 198: return L("Uncorrectable sectors")
        case 199: return L("Interface CRC errors")
        case 202: return L("Lifetime remaining")
        case 231: return L("SSD life left")
        case 233: return L("Media wearout indicator")
        case 241: return L("Total LBAs written")
        case 242: return L("Total LBAs read")
        default: return L("Vendor specific")
        }
    }

    /// One line for a further internal drive (Fusion Drive hard disk, second SSD).
    public static func driveSummary(_ drive: ATADrive) -> String {
        let kind = drive.isSolidState ? L("SSD") : L("Hard disk")
        let findings = drive.health.map(ataFindings) ?? []
        let state = drive.health == nil ? L("SMART not readable")
            : findings.isEmpty ? L("SMART: no problems") : findings.joined(separator: " ")
        return [kind, drive.capacity.map { Format.bytes($0) }, state].compactMap { $0 }.joined(separator: " · ")
    }

    public static func finding(_ f: SSDStressTest.Result.Finding) -> String {
        switch f {
        case let .dataMismatch(chunks, first):
            return L("Data read back did not match in %lld blocks (first at %@) — failing NAND or controller", chunks, Format.bytes(Double(first) * 8_388_608))
        case let .ioErrors(count):
            return L("%lld read / write errors", count)
        case let .slowChunks(count, worst):
            return L("%lld blocks were very slow (worst %@ ms) — possible weak NAND or retries", count, Format.number(worst * 1000))
        case let .smartMediaErrorsIncreased(by):
            return L("SMART media errors increased by %@ during the test", Format.number(by))
        case let .smartErrorLogIncreased(by):
            return L("SMART error log grew by %@ entries during the test", Format.number(by))
        case .stoppedEarly:
            return L("Test was stopped before the planned duration")
        case .notEnoughSpace:
            return L("Not enough free space for the test")
        }
    }

    public static func resultRows(_ r: SSDStressTest.Result) -> [(String, String)] {
        var rows: [(String, String)] = [
            (L("Tested"), Format.bytes(r.testedBytes)),
            (L("Write speed"), r.writeSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
            (L("Read speed"), r.readSpeed.map { Format.speed(megabytesPerSecond: $0) } ?? "–"),
        ]
        let writes = r.timings.map(\.write).sorted()
        let reads = r.timings.compactMap(\.read).sorted()
        if let worst = writes.last {
            rows.append((L("Slowest block write"), "\(Format.number(worst * 1000)) ms"))
        }
        if let worst = reads.last {
            rows.append((L("Slowest block read"), "\(Format.number(worst * 1000)) ms"))
        }
        return rows
    }
}
