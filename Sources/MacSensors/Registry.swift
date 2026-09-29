import Foundation
import IOKit

/// The default IOKit main port (`ioMainPort`, macOS 12+; `kIOMasterPortDefault`
/// before). Both are MACH_PORT_NULL, which works on every macOS version.
let ioMainPort: mach_port_t = mach_port_t(MACH_PORT_NULL)

/// Helpers for reading IORegistry properties.
enum Registry {
    /// All properties of the first service matching `className`.
    static func properties(ofClass className: String) -> [String: Any]? {
        let service = IOServiceGetMatchingService(ioMainPort, IOServiceMatching(className))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        return properties(of: service)
    }

    static func properties(of entry: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// A single property of the device tree root's platform expert, as string.
    static func platformString(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(ioMainPort, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        if let string = value as? String { return string }
        if let data = value as? Data {
            // Device tree strings are NUL terminated byte arrays.
            let bytes = data.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return nil
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        (self[key] as? NSNumber).map { Int($0.int64Value) }
    }

    func bool(_ key: String) -> Bool? {
        (self[key] as? NSNumber)?.boolValue
    }

    func string(_ key: String) -> String? {
        self[key] as? String
    }

    func dict(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    func intArray(_ key: String) -> [Int]? {
        (self[key] as? [NSNumber])?.map { Int($0.int64Value) }
    }
}
