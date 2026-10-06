import Foundation
import IOKit

/// Read / write counters macOS keeps for a disk since startup (the `Statistics` of its
/// IOBlockStorageDriver). Errors and retries mean the drive failed to deliver data the system
/// asked for; they need neither SMART nor root, so they work on every Mac.
public struct DiskIOStatistics: Codable, Sendable, Equatable {
    public var readErrors: Int
    public var writeErrors: Int
    public var readRetries: Int
    public var writeRetries: Int
    public var bytesRead: Double
    public var bytesWritten: Double

    public init(readErrors: Int, writeErrors: Int, readRetries: Int, writeRetries: Int,
                bytesRead: Double, bytesWritten: Double) {
        self.readErrors = readErrors
        self.writeErrors = writeErrors
        self.readRetries = readRetries
        self.writeRetries = writeRetries
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }

    public var errors: Int { readErrors + writeErrors }
    public var retries: Int { readRetries + writeRetries }

    init?(_ statistics: [String: Any]) {
        func int(_ key: String) -> Int { (statistics[key] as? NSNumber)?.intValue ?? 0 }
        func double(_ key: String) -> Double { (statistics[key] as? NSNumber)?.doubleValue ?? 0 }
        guard statistics["Operations (Read)"] != nil || statistics["Bytes (Read)"] != nil else { return nil }
        self.init(readErrors: int("Errors (Read)"), writeErrors: int("Errors (Write)"),
                  readRetries: int("Retries (Read)"), writeRetries: int("Retries (Write)"),
                  bytesRead: double("Bytes (Read)"), bytesWritten: double("Bytes (Write)"))
    }

    /// The counters of the driver above a block storage device (its child in the registry).
    static func below(_ device: io_service_t) -> DiskIOStatistics? {
        guard let statistics = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "Statistics" as CFString,
                                                               kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively))
            as? [String: Any]
        else { return nil }
        return DiskIOStatistics(statistics)
    }

    /// Internal block storage devices with their product name and counters.
    static func internalDevices() -> [(model: String?, statistics: DiskIOStatistics)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [(String?, DiskIOStatistics)] = []
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            defer { IOObjectRelease(service) }
            guard let properties = Registry.properties(of: service),
                  (properties.dict("Protocol Characteristics")?.string("Physical Interconnect Location") ?? "Internal") == "Internal",
                  let statistics = below(service)
            else { continue }
            let model = properties.dict("Device Characteristics")?.string("Product Name")?.trimmingCharacters(in: .whitespaces)
            out.append((model, statistics))
        }
        return out
    }
}
