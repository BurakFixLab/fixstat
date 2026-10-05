import CMacSensors
import Foundation
import IOKit

/// One attribute of the ATA SMART data structure.
public struct ATASMARTAttribute: Codable, Sendable, Equatable {
    public var id: Int
    /// Normalized value (vendor scale, usually 100 or 200 = new, lower = worse).
    public var current: Int
    public var worst: Int
    /// Failure threshold (0 = none or not reported).
    public var threshold: Int
    /// Raw value (6 bytes, little endian); its meaning is vendor specific.
    public var raw: UInt64

    /// Below its threshold: the drive considers this attribute failed.
    public var failing: Bool { threshold > 0 && current <= threshold }
}

/// SMART of an ATA / SATA (AHCI) drive: attribute table, thresholds and the drive's own
/// verdict (SMART RETURN STATUS).
public struct ATAHealth: Codable, Sendable, Equatable {
    public var attributes: [ATASMARTAttribute]
    /// The drive reports a threshold exceeded condition (nil: not reported).
    public var thresholdExceeded: Bool?

    /// Well-known attribute ids.
    public enum ID {
        public static let reallocated = 5
        public static let powerOnHours = 9
        public static let powerCycles = 12
        public static let unsafeShutdowns = 192
        public static let temperature = 194
        public static let reallocationEvents = 196
        public static let pending = 197
        public static let uncorrectable = 198
        public static let crcErrors = 199
        public static let totalLBAsWritten = 241
        public static let totalLBAsRead = 242
        /// Attributes whose normalized value is the remaining life in % on SSDs, in the order
        /// they are trusted: SSD Life Left, Remaining Lifetime, Media Wearout Indicator,
        /// Wear Leveling Count (Samsung, Apple SM…), Percent Lifetime Remaining (Crucial),
        /// Average Erase Count / Wear Leveling (SanDisk, Toshiba, Apple SD… / TS…).
        public static let lifeLeft = [231, 169, 233, 177, 202, 173]
    }

    /// Parses the 512-byte SMART data and threshold structures (ATA/ATAPI-6, 8.54):
    /// 30 attribute entries of 12 bytes from offset 2.
    public static func parse(data: [UInt8], thresholds: [UInt8], exceeded: Int32) -> ATAHealth? {
        guard data.count >= 512 else { return nil }
        var limits: [Int: Int] = [:]
        if thresholds.count >= 512 {
            for entry in 0..<30 {
                let offset = 2 + entry * 12
                if thresholds[offset] != 0 { limits[Int(thresholds[offset])] = Int(thresholds[offset + 1]) }
            }
        }
        var attributes: [ATASMARTAttribute] = []
        for entry in 0..<30 {
            let offset = 2 + entry * 12
            let id = Int(data[offset])
            guard id != 0 else { continue }
            var raw: UInt64 = 0
            for index in (0..<6).reversed() { raw = raw << 8 | UInt64(data[offset + 5 + index]) }
            attributes.append(ATASMARTAttribute(id: id, current: Int(data[offset + 3]), worst: Int(data[offset + 4]),
                                                threshold: limits[id] ?? 0, raw: raw))
        }
        guard !attributes.isEmpty else { return nil }
        return ATAHealth(attributes: attributes, thresholdExceeded: exceeded < 0 ? nil : exceeded == 1)
    }

    public func attribute(_ id: Int) -> ATASMARTAttribute? {
        attributes.first { $0.id == id }
    }

    /// Low 32 bits of a raw value: counters such as power-on hours pack more data above.
    func counter(_ id: Int) -> Double? {
        attribute(id).map { Double($0.raw & 0xFFFF_FFFF) }
    }

    public var powerOnHours: Double? { counter(ID.powerOnHours) }
    public var powerCycles: Double? { counter(ID.powerCycles) }
    public var unsafeShutdowns: Double? { counter(ID.unsafeShutdowns) }
    public var reallocatedSectors: Double? { counter(ID.reallocated) }
    public var pendingSectors: Double? { counter(ID.pending) }
    public var uncorrectableSectors: Double? { counter(ID.uncorrectable) }
    public var crcErrors: Double? { counter(ID.crcErrors) }
    public var temperature: Double? {
        attribute(ID.temperature).map { Double($0.raw & 0xFF) }.flatMap { (1...120).contains($0) ? $0 : nil }
    }

    /// Total data written, assuming 512-byte LBAs (most SSDs; some count in larger units).
    public var bytesWritten: Double? { attribute(ID.totalLBAsWritten).map { Double($0.raw) * 512 } }

    /// Remaining life in % from the first life attribute whose normalized value is a
    /// percentage, and that attribute's id. A vendor estimate, like NVMe's percentage used.
    public var lifeLeft: (percent: Int, attribute: Int)? {
        for id in ID.lifeLeft {
            if let a = attribute(id), (1...100).contains(a.current) { return (a.current, id) }
        }
        return nil
    }

    /// Attributes below their failure threshold.
    public var failingAttributes: [ATASMARTAttribute] { attributes.filter(\.failing) }
}

/// An internal SMART capable ATA drive (AHCI SSD, SATA SSD or hard disk).
public struct ATADrive: Codable, Sendable, Equatable {
    public var model: String?
    public var firmware: String?
    public var serial: String?
    /// "Solid State" or "Rotational".
    public var medium: String?
    /// "SATA", "PCI-Express" …
    public var interconnect: String?
    /// Bytes.
    public var capacity: Double?
    public var health: ATAHealth?

    public var isSolidState: Bool { medium?.localizedCaseInsensitiveContains("solid") ?? true }

    /// Every internal SMART capable ATA block device.
    public static func readAll(includeSerial: Bool = false) -> [ATADrive] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var drives: [ATADrive] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let properties = Registry.properties(of: service),
                  (properties["SMART Capable"] as? NSNumber)?.boolValue == true else { continue }
            let device = properties.dict("Device Characteristics") ?? [:]
            let protocolInfo = properties.dict("Protocol Characteristics") ?? [:]
            guard (protocolInfo.string("Physical Interconnect Location") ?? "Internal") == "Internal" else { continue }
            var drive = ATADrive()
            drive.model = device.string("Product Name")?.trimmingCharacters(in: .whitespaces)
            drive.firmware = device.string("Product Revision Level")?.trimmingCharacters(in: .whitespaces)
            if let serial = device.string("Serial Number")?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
                drive.serial = includeSerial ? serial : Privacy.mask(serial)
            }
            drive.medium = device.string("Medium Type")
            drive.interconnect = protocolInfo.string("Physical Interconnect")
            drive.capacity = mediaSize(below: service)
            var data = [UInt8](repeating: 0, count: 512)
            var thresholds = [UInt8](repeating: 0, count: 512)
            var exceeded: Int32 = -1
            if FSATAReadSMART(service, &data, &thresholds, &exceeded) == KERN_SUCCESS {
                drive.health = ATAHealth.parse(data: data, thresholds: thresholds, exceeded: exceeded)
            }
            drives.append(drive)
        }
        return drives
    }

    /// Size of the whole-disk IOMedia below a block storage device.
    static func mediaSize(below service: io_service_t) -> Double? {
        guard let size = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "Size" as CFString, kCFAllocatorDefault,
                                                         IOOptionBits(kIORegistryIterateRecursively)) as? NSNumber
        else { return nil }
        return size.doubleValue
    }
}

/// Space on the startup volume (the APFS container is shared by its volumes; "used" is what
/// is not available, as Finder shows it).
public struct VolumeSpace: Codable, Sendable, Equatable {
    public var total: Double
    public var available: Double
    public var used: Double { max(0, total - available) }

    public static func startup() -> VolumeSpace? {
        let url = URL(fileURLWithPath: "/")
        var keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        if #available(macOS 10.13, *) { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else { return nil }
        // "Important usage" counts purgeable space as available, like Finder.
        let available = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
            ?? values.volumeAvailableCapacity.map(Double.init) ?? 0
        return VolumeSpace(total: Double(total), available: available)
    }
}
