import Foundation
import IOKit

/// Internal or external, for block storage devices and NVMe controllers.
///
/// A drive is external when its `Protocol Characteristics` say "External", or when it sits behind a
/// Thunderbolt PCIe tunnel (`IOPCITunnelled` on a PCI device above it): NVMe drives in Thunderbolt
/// enclosures can report "Internal" like a drive on the Mac's own PCIe bus (Disk Utility then lists
/// them under Internal).
enum StorageLocation {
    /// "Internal", "External", "File" (disk image), "Virtual" …; nil when not reported.
    static func location(of service: io_service_t) -> String? {
        Registry.properties(of: service)?.dict("Protocol Characteristics")?.string("Physical Interconnect Location")
    }

    /// A PCI device above the entry is tunnelled through Thunderbolt.
    static func isThunderbolt(_ service: io_service_t) -> Bool {
        let value = IORegistryEntrySearchCFProperty(service, kIOServicePlane, "IOPCITunnelled" as CFString, kCFAllocatorDefault,
                                                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return (value as? NSNumber)?.boolValue == true
    }

    static func isExternal(_ service: io_service_t) -> Bool {
        location(of: service) == "External" || isThunderbolt(service)
    }

    /// The Mac's own drive: "Internal" (or not reported) and not behind Thunderbolt.
    static func isInternal(_ service: io_service_t) -> Bool {
        (location(of: service) ?? "Internal") == "Internal" && !isThunderbolt(service)
    }

    /// Calls `body` for every block storage device (the services are released afterwards).
    static func forEachBlockDevice(_ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching("IOBlockStorageDevice"), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            body(service)
            IOObjectRelease(service)
        }
    }

    /// The first internal block storage device (retained; the caller releases it), preferring an
    /// NVMe one.
    static func internalBlockDevice(nvmeOnly: Bool = false) -> io_service_t? {
        var nvme: io_service_t?
        var other: io_service_t?
        forEachBlockDevice { service in
            guard isInternal(service) else { return }
            let isNVMe = (Registry.properties(of: service)?["NVMe SMART Capable"] as? NSNumber)?.boolValue == true
            if isNVMe, nvme == nil {
                IOObjectRetain(service)
                nvme = service
            } else if !isNVMe, other == nil, !nvmeOnly {
                IOObjectRetain(service)
                other = service
            }
        }
        if let nvme {
            if let other { IOObjectRelease(other) }
            return nvme
        }
        return other
    }

    /// The NVMe controller above a block storage device (retained), e.g. the internal SSD's.
    static func nvmeController(above service: io_service_t) -> io_service_t? {
        var current = service
        IOObjectRetain(current)
        for _ in 0..<16 {
            if IOObjectConformsTo(current, "IONVMeController") != 0 { return current }
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(current)
            current = parent
        }
        IOObjectRelease(current)
        return nil
    }
}
