import CMacSensors
import Foundation
import IOKit

/// NVMe SMART / Health Information (NVMe base specification, log page 02h).
public struct NVMeHealth: Codable, Sendable, Equatable {
    /// Bit field: 0 spare below threshold, 1 temperature, 2 reliability degraded,
    /// 3 read-only, 4 volatile backup failed.
    public var criticalWarning: Int
    /// °C (composite temperature).
    public var temperature: Double?
    /// Available spare in %.
    public var availableSpare: Int
    public var availableSpareThreshold: Int
    /// Vendor estimate of life used in % (can exceed 100).
    public var percentageUsed: Int
    /// Bytes (data units × 512 000).
    public var bytesRead: Double
    public var bytesWritten: Double
    public var powerCycles: Double
    public var powerOnHours: Double
    public var unsafeShutdowns: Double
    public var mediaErrors: Double
    public var errorLogEntries: Double

    public static func parse(_ log: [UInt8]) -> NVMeHealth? {
        guard log.count >= 512 else { return nil }
        /// Little-endian 128-bit counter, as Double (exact up to 2^53).
        func counter(_ offset: Int) -> Double {
            var value = 0.0
            for index in (0..<16).reversed() { value = value * 256 + Double(log[offset + index]) }
            return value
        }
        let kelvin = Int(log[1]) | Int(log[2]) << 8
        return NVMeHealth(
            criticalWarning: Int(log[0]),
            temperature: kelvin > 0 ? Double(kelvin) - 273.15 : nil,
            availableSpare: Int(log[3]),
            availableSpareThreshold: Int(log[4]),
            percentageUsed: Int(log[5]),
            bytesRead: counter(32) * 512_000,
            bytesWritten: counter(48) * 512_000,
            powerCycles: counter(112),
            powerOnHours: counter(128),
            unsafeShutdowns: counter(144),
            mediaErrors: counter(160),
            errorLogEntries: counter(176)
        )
    }

    public var warnings: [String] {
        let names = ["spareBelowThreshold", "temperature", "reliabilityDegraded", "readOnly", "volatileBackupFailed"]
        return names.enumerated().compactMap { criticalWarning & (1 << $0.offset) != 0 ? $0.element : nil }
    }
}

/// The internal SSD (NVMe, or an AHCI / SATA drive on older Intel Macs) from the IORegistry.
/// The serial number is masked unless requested.
public struct SSDInfo: Codable, Sendable, Equatable {
    public var model: String?
    public var firmware: String?
    /// Bytes.
    public var capacity: Double?
    public var nandVendor: String?
    public var nandType: String?
    public var bitsPerCell: Int?
    public var serial: String?
    /// NVMe SMART / health log.
    public var health: NVMeHealth?
    /// ATA SMART of an AHCI / SATA SSD (when there is no NVMe SSD).
    public var ata: ATAHealth?
    /// "PCI-Express", "SATA", "Apple Fabric" …
    public var interconnect: String?
    /// Space on the startup volume.
    public var space: VolumeSpace?
    /// Further internal ATA drives, e.g. the hard disk of a Fusion Drive iMac.
    public var otherDrives: [ATADrive] = []
    /// Why there is no SMART data: "no SMART capable drive" or the read's IOKit return code.
    public var smartProblem: String?
    /// Read / write errors and retries of the SSD since startup (no SMART needed).
    public var io: DiskIOStatistics?

    /// Health in %: 100 − NVMe "percentage used", or the life attribute of ATA SMART. A
    /// vendor estimate of the remaining rated endurance.
    public var healthPercent: Int? {
        if let health { return max(0, 100 - health.percentageUsed) }
        return ata?.lifeLeft?.percent
    }

    public var isNVMe: Bool { health != nil || nandVendor != nil }

    public static func read(includeSerial: Bool = false) -> SSDInfo? {
        var info = SSDInfo()
        if let controller = Registry.properties(ofClass: "IONVMeController") {
            info.model = (controller.string("Model Number"))?.trimmingCharacters(in: .whitespaces)
            info.firmware = (controller.string("Firmware Revision"))?.trimmingCharacters(in: .whitespaces)
            if let characteristics = controller.dict("Controller Characteristics") {
                info.capacity = (characteristics["capacity"] as? NSNumber)?.doubleValue
                info.nandVendor = characteristics.string("vendor-name")?.trimmingCharacters(in: .whitespaces)
                info.nandType = characteristics.string("nand-marketing-name")?.trimmingCharacters(in: .whitespaces)
                info.bitsPerCell = characteristics.int("default-bits-per-cell")
            }
            if let serial = controller.string("Serial Number")?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
                info.serial = includeSerial ? serial : Privacy.mask(serial)
            }
        }
        info.health = readHealth()
        if let device = Registry.properties(ofClass: "IOBlockStorageDevice") {
            let characteristics = device.dict("Device Characteristics") ?? [:]
            if info.model == nil { info.model = characteristics.string("Product Name")?.trimmingCharacters(in: .whitespaces) }
            if info.firmware == nil {
                info.firmware = characteristics.string("Product Revision Level")?.trimmingCharacters(in: .whitespaces)
            }
            info.interconnect = device.dict("Protocol Characteristics")?.string("Physical Interconnect")
        }
        if info.capacity == nil {
            // Intel NVMe (no "Controller Characteristics"): the size of the disk medium.
            let service = IOServiceGetMatchingService(ioMainPort, IOServiceMatching("IOBlockStorageDevice"))
            if service != IO_OBJECT_NULL {
                info.capacity = ATADrive.mediaSize(below: service)
                IOObjectRelease(service)
            }
        }
        var drives = ATADrive.readAll(includeSerial: includeSerial)
        if info.health == nil, let index = drives.firstIndex(where: { $0.isSolidState }) ?? drives.indices.first {
            // No NVMe SSD: the (first solid state) ATA drive is the SSD.
            let drive = drives.remove(at: index)
            info.model = drive.model ?? info.model
            info.firmware = drive.firmware ?? info.firmware
            info.serial = drive.serial ?? info.serial
            info.capacity = drive.capacity ?? info.capacity
            info.interconnect = drive.interconnect ?? info.interconnect
            info.ata = drive.health
            info.io = drive.io
            info.smartProblem = drive.smartError.map { "SMART read failed (\($0))" }
        } else if info.health == nil {
            info.smartProblem = "no SMART capable drive (\(Self.storageClasses()))"
        }
        info.otherDrives = drives
        if info.io == nil {
            let devices = DiskIOStatistics.internalDevices()
            info.io = (devices.first { $0.model != nil && $0.model == info.model } ?? devices.first)?.statistics
        }
        info.space = VolumeSpace.startup()
        if UserDefaults.standard.bool(forKey: "FixStatSampleATA") { info = sampleATA(space: info.space) }
        guard info.model != nil || info.health != nil || info.ata != nil else { return nil }
        return info
    }

    public static func readHealth() -> NVMeHealth? {
        var log = [UInt8](repeating: 0, count: 512)
        guard FSNVMeReadSMARTLog(&log) == KERN_SUCCESS else { return nil }
        return NVMeHealth.parse(log)
    }
}

extension SSDInfo {
    /// Classes of the block storage devices, e.g. "IOAHCIBlockStorageDevice": which driver the
    /// Mac uses when no SMART capable drive was found.
    static func storageClasses() -> String {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS
        else { return "none" }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            var name = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(service, &name)
            let smart = (Registry.properties(of: service)?["SMART Capable"] as? NSNumber).map { $0.boolValue ? " SMART" : "" } ?? ""
            names.append(Registry.string(from: name) + smart)
            IOObjectRelease(service)
        }
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    /// `-FixStatSampleATA YES`: a made-up AHCI SSD with a Fusion-style hard disk, for checking
    /// the AHCI screens on a Mac with an NVMe SSD.
    static func sampleATA(space: VolumeSpace?) -> SSDInfo {
        func health(_ attributes: [(Int, Int, Int, Int, UInt64)]) -> ATAHealth {
            ATAHealth(attributes: attributes.map {
                ATASMARTAttribute(id: $0.0, current: $0.1, worst: $0.2, threshold: $0.3, raw: $0.4)
            }, thresholdExceeded: false)
        }
        var info = SSDInfo()
        info.model = "APPLE SSD SM0256F"
        info.firmware = "UXM2JA1Q"
        info.capacity = 251_000_193_024
        info.interconnect = "PCI-Express"
        info.space = space
        info.ata = health([(1, 200, 200, 0, 0), (5, 100, 100, 10, 0), (9, 98, 98, 0, 6_120), (12, 98, 98, 0, 2_311),
                           (177, 93, 93, 0, 61), (179, 100, 100, 10, 0), (181, 100, 100, 10, 0), (182, 100, 100, 10, 0),
                           (194, 71, 49, 0, 29), (199, 200, 200, 0, 0), (241, 99, 99, 0, 21_474_836_480)])
        // privacy:allow on the next line: a Seagate model number, not a serial.
        info.otherDrives = [ATADrive(model: "ST1000DM003-1ER162", firmware: "CC43", serial: nil, medium: "Rotational", // privacy:allow
                                     interconnect: "SATA", capacity: 1_000_204_886_016,
                                     health: health([(5, 100, 100, 36, 8), (9, 63, 63, 0, 32_870), (197, 100, 100, 0, 16),
                                                     (199, 200, 200, 0, 0)]))]
        return info
    }
}
