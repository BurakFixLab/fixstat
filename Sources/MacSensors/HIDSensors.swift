import CMacSensors
import Foundation

/// One reading from an IOHIDEventSystem sensor service.
public struct HIDReading: Codable, Sendable, Equatable {
    /// The service's "Product" property, e.g. "PMU tdie1" or "NAND CH0 temp".
    public let name: String
    public let value: Double
    /// The service's LocationID decoded as FourCC. On Apple Silicon this is the
    /// matching SMC key (e.g. "gas gauge battery" → "TG0B"); nil if not printable.
    public let key: String?

    public init(name: String, value: Double, key: String? = nil) {
        self.name = name
        self.value = value
        self.key = key
    }
}

/// Reads sensors exposed through the private IOHIDEventSystemClient API
/// (Apple Silicon; partially also T2 Intel Macs).
///
/// Create one reader per sensor kind and reuse it; creating the client is the
/// expensive part.
public final class HIDSensorReader: @unchecked Sendable {
    public enum Kind: Sendable {
        /// Temperatures in °C.
        case temperature
        /// Current sensors (Apple vendor power page). Raw event value; units and
        /// validity unverified — many rails report implausible numbers.
        case current
        /// Voltage sensors (Apple vendor power page). Raw event value; units and
        /// validity unverified.
        case voltage

        var usagePage: Int32 {
            switch self {
            case .temperature: 0xff00
            case .current, .voltage: 0xff08
            }
        }

        var usage: Int32 {
            switch self {
            case .temperature: 0x0005
            case .current: 0x0002
            case .voltage: 0x0003
            }
        }

        var eventType: Int64 {
            switch self {
            case .temperature: Int64(FSHIDEventTypeTemperature)
            case .current, .voltage: Int64(FSHIDEventTypePower)
            }
        }
    }

    public let kind: Kind
    private let client: CFTypeRef

    public init?(kind: Kind) {
        guard let client = FSHIDClientCreate(kind.usagePage, kind.usage) else { return nil }
        self.kind = kind
        self.client = client
    }

    /// Current readings, sorted by name.
    public func read() -> [HIDReading] {
        guard let array = FSHIDClientCopyReadings(client, kind.eventType) as? [[String: Any]] else { return [] }
        return array.compactMap { entry -> HIDReading? in
            guard let name = entry["name"] as? String, let value = entry["value"] as? Double else { return nil }
            let key = (entry["locationID"] as? NSNumber).flatMap { HIDReading.fourCC($0.uint32Value) }
            return HIDReading(name: name, value: value, key: key)
        }
        .sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? ($0.key ?? "") < ($1.key ?? "") : order == .orderedAscending
        }
    }
}

extension HIDReading {
    /// A LocationID as four printable ASCII characters, or nil.
    static func fourCC(_ value: UInt32) -> String? {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }
}
