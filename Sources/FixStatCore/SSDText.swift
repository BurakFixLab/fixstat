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

    /// SMART of an AHCI / SATA drive could not be read and FixStat has no Full Disk Access:
    /// macOS opens the ATA SMART interface only to apps with it (DriveDx asks for it too).
    public static func needsFullDiskAccess(_ info: SSDInfo) -> Bool {
        info.health == nil && info.ata == nil && info.smartProblem?.hasPrefix("SMART read failed") == true
            && !FullSSDRunner.hasFullDiskAccess
    }

    public static var fullDiskAccessHint: String {
        L("macOS lets apps read the SMART data of this SSD only with Full Disk Access: System Settings › Privacy & Security › Full Disk Access › turn FixStat on, then open this window again.")
    }

    /// "162 GB used of 245 GB · 83 GB free" (the internal SSD).
    public static func space(_ space: VolumeSpace) -> String {
        let text = L("%@ used of %@ · %@ free", Format.bytes(space.used), Format.bytes(space.total), Format.bytes(space.available))
        return space.startedFromOtherDisk == true ? text + " · " + L("internal SSD (the Mac was started from another disk)") : text
    }

    /// Where the write–verify test writes when the Mac was started from another disk; nil when it
    /// runs from the internal SSD.
    public static var testLocationNote: String? {
        guard !InternalStorage.startedFromInternal else { return nil }
        guard let directory = InternalStorage.testDirectory() else {
            return L("The Mac was started from another disk and the internal SSD is not mounted (or still locked with FileVault). Mount it in Disk Utility to test it.")
        }
        let name = (try? directory.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? directory.path
        return L("The Mac was started from another disk: the test writes to the internal SSD (%@).", name)
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
        if let written = h.bytesWritten {
            rows.append((h.isAppleSanDisk ? L("Data written") : L("Data written (estimate)"), Format.bytes(written)))
        }
        if let read = h.bytesRead, h.isAppleSanDisk { rows.append((L("Data read"), Format.bytes(read))) }
        if let erase = h.eraseCounts {
            rows.append((L("NAND erase cycles"), L("average %1$lld (lowest %2$lld, highest %3$lld)",
                                                     erase.average, erase.minimum, erase.maximum)))
        }
        if let temperature = h.temperature { rows.append((L("Temperature"), Format.temperature(temperature, digits: 0))) }
        return rows
    }

    /// All attributes: id, name, current, worst, threshold, raw.
    public static func ataTable(_ h: ATAHealth) -> [[String]] {
        h.attributes.map { a in
            [String(a.id), attributeName(a.id, appleSanDisk: h.isAppleSanDisk), String(a.current), String(a.worst),
             a.threshold > 0 ? String(a.threshold) : "–", String(a.raw)]
        }
    }

    public static var ataTableHeader: [String] {
        [L("ID"), L("Attribute"), L("Value"), L("Worst"), L("Threshold"), L("Raw")]
    }

    public static func attributeName(_ id: Int, appleSanDisk: Bool = false) -> String {
        if appleSanDisk {
            switch id {
            case 173: return L("Erase count (average, highest, lowest)")
            case 174: return L("Host reads (MiB)")
            case 175: return L("Host writes (MiB)")
            default: break
            }
        }
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
        case 190: return L("Airflow temperature")
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
    /// "Since startup: no read or write errors · 170 GB read · 92 GB written".
    public static func io(_ s: DiskIOStatistics) -> String {
        let state = s.errors == 0 && s.retries == 0 ? L("no read or write errors")
            : L("%1$lld read / write errors, %2$lld retries", s.errors, s.retries)
        return L("Since startup: %@", [state, L("%@ read", Format.bytes(s.bytesRead)),
                                       L("%@ written", Format.bytes(s.bytesWritten))].joined(separator: " · "))
    }

    /// A finding when the drive failed reads or writes since startup.
    public static func ioFinding(_ s: DiskIOStatistics) -> String? {
        guard s.errors > 0 || s.retries > 0 else { return nil }
        return L("The drive failed %1$lld reads or writes since startup (%2$lld retries): back up the data and run the stress test.",
                 s.errors, s.retries)
    }

    public static func driveSummary(_ drive: ATADrive) -> String {
        let kind = drive.isSolidState ? L("SSD") : L("Hard disk")
        let findings = (drive.health.map(ataFindings) ?? []) + [drive.io.flatMap(ioFinding)].compactMap { $0 }
        let state = drive.health == nil ? L("SMART not readable")
            : findings.isEmpty ? L("SMART: no problems") : findings.joined(separator: " ")
        return [kind, drive.capacity.map { Format.bytes($0) }, state].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: External drives

    /// "SSD · 500 GB · USB 5 Gb/s · Ugreen Storage Device (ASMedia, 174c:1153) · disk4";
    /// "SSD · 2 TB · Thunderbolt · FW 3B2QGXA7 · disk5".
    public static func externalIdentity(_ drive: ATADrive) -> String {
        let kind = drive.isSolidState ? L("SSD") : L("Hard disk")
        let link = drive.thunderbolt == true ? "Thunderbolt"
            : drive.usb?.megabitsPerSecond.map { "USB " + PortText.speed($0) } ?? drive.interconnect.map(interconnect)
        let bridge = drive.usb.map { usb -> String in
            let chip = [usb.chipVendor, usb.vendorID.flatMap { vendor in
                usb.productID.map { String(format: "%04x:%04x", vendor, $0) }
            }].compactMap { $0 }.joined(separator: ", ")
            guard let name = usb.name, !name.isEmpty else { return chip }
            return chip.isEmpty ? name : name + " (" + chip + ")"
        }
        // USB bridges often report "0" instead of the drive's firmware.
        let firmware = drive.firmware.flatMap { $0.allSatisfy { "0. ".contains($0) } ? nil : "FW " + $0 }
        return [kind, drive.capacity.map { Format.bytes($0) }, link, bridge, firmware, drive.bsdName]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "Health 99 % (SMART attribute 177, vendor estimate)"; nil without a life attribute.
    public static func healthSummary(_ h: ATAHealth) -> String? {
        guard let life = h.lifeLeft else { return nil }
        return L("Health %@ (SMART attribute %lld, vendor estimate)", Format.percent(Double(life.percent)), life.attribute)
    }

    /// "Health 97 % (3 % of the rated endurance used)".
    public static func healthSummary(_ h: NVMeHealth) -> String {
        L("Health %@ (%@ of the rated endurance used)", Format.percent(Double(max(0, 100 - h.percentageUsed))),
          Format.percent(Double(h.percentageUsed)))
    }

    /// The drive's SMART was read (ATA through a USB bridge, or NVMe).
    public static func externalHasSMART(_ drive: ATADrive) -> Bool {
        drive.health != nil || drive.nvmeHealth != nil
    }

    public static func externalHealthSummary(_ drive: ATADrive) -> String? {
        if let h = drive.nvmeHealth { return healthSummary(h) }
        return drive.health.flatMap(healthSummary)
    }

    public static func externalHealthRows(_ drive: ATADrive) -> [(String, String)] {
        if let h = drive.nvmeHealth { return healthRows(h) }
        return drive.health.map(ataRows) ?? []
    }

    /// The ATA attribute table; nil for NVMe and drives without SMART.
    public static func externalAttributes(_ drive: ATADrive) -> [[String]]? {
        drive.health.map(ataTable)
    }

    /// SMART findings and read / write errors since startup. CRC errors of a drive in an enclosure
    /// come from the link between the drive and the adapter, not from a SATA cable in a Mac.
    public static func externalFindings(_ drive: ATADrive) -> [String] {
        var findings = drive.nvmeHealth.map(healthFindings) ?? drive.health.map(ataFindings) ?? []
        if drive.usb != nil, let count = drive.health?.crcErrors, count > 0,
           let index = findings.firstIndex(of: L("%@ interface CRC errors: check the SATA cable / flex and the connector.",
                                                  Format.number(count))) {
            findings[index] = L("%@ interface CRC errors between the drive and the USB adapter: check the enclosure's connector and the adapter (pulling the drive out while it is busy counts too).",
                                Format.number(count))
        }
        return findings + [drive.io.flatMap(ioFinding)].compactMap { $0 }
    }

    /// macOS passes ATA SMART through USB–SATA adapters from this major version on: 27 does, 11 does
    /// not (the same ASMedia enclosure and UAS driver chain, no "SMART Capable" on Big Sur); the
    /// versions in between are not known yet.
    static let usbSMARTKnownFrom = 27

    /// Why an external drive shows no SMART data; nil when it has SMART.
    public static func externalSMARTProblem(_ drive: ATADrive,
                                            macOSMajor: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion) -> String? {
        guard !externalHasSMART(drive) else { return nil }
        if drive.smartCapable == true {
            return L("SMART read failed (%@).", drive.smartError ?? "–")
        }
        if drive.usb == nil {
            return L("This drive does not offer SMART data. Read / write errors are counted.")
        }
        if macOSMajor < usbSMARTKnownFrom {
            return L("SMART data does not come through USB here: the USB adapter does not pass it on, or this macOS version does not (macOS 11 does not; macOS 27 does with the same adapter). Read / write errors are counted.")
        }
        return L("The USB adapter does not pass SMART data on (common with USB–NVMe adapters, memory sticks and card readers). Read / write errors are counted.")
    }

    /// ATA SMART of an external drive could not be read and FixStat has no Full Disk Access.
    public static func needsFullDiskAccess(_ drive: ATADrive) -> Bool {
        !externalHasSMART(drive) && drive.smartCapable == true && drive.nvme != true && !FullSSDRunner.hasFullDiskAccess
    }

    /// One line for the PDF report: identity, health and findings.
    public static func externalSummary(_ drive: ATADrive) -> String {
        let findings = externalFindings(drive)
        let state: String
        if externalHasSMART(drive) {
            state = ([externalHealthSummary(drive)].compactMap { $0 }
                + [findings.isEmpty ? L("SMART: no problems") : findings.joined(separator: " ")]).joined(separator: " · ")
        } else {
            state = ([L("SMART not readable")] + findings).joined(separator: " ")
        }
        return externalIdentity(drive) + " · " + state
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
