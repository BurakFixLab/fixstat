import CMacSensors
import Foundation

/// A four-character code as used for SMC keys and data types.
public struct FourCC: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Creates a code from up to four ASCII characters; shorter strings are space padded.
    public init(_ string: String) {
        var value: UInt32 = 0
        let bytes = Array(string.utf8.prefix(4)) + Array(repeating: UInt8(ascii: " "), count: max(0, 4 - string.utf8.count))
        for byte in bytes {
            value = value << 8 | UInt32(byte)
        }
        rawValue = value
    }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> $0) }
        return String(decoding: bytes.map { (32...126).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
    }
}

/// A raw SMC value together with its type.
public struct SMCValue: Sendable {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]

    public init(key: FourCC, type: FourCC, bytes: [UInt8]) {
        self.key = key
        self.type = type
        self.bytes = bytes
    }

    /// Numeric interpretation of the value, or nil for non-numeric types.
    public var doubleValue: Double? {
        SMCValue.decode(type: type.description, bytes: bytes)
    }

    public var hexString: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Decodes the numeric SMC data types.
    ///
    /// - `flt `: IEEE 754 float, little endian (Apple Silicon).
    /// - `ui8 `/`ui16`/`ui32`/`ui64`, `si8 `/`si16`/`si32`/`si64`: big endian integers.
    /// - `fpXY` / `spXY`: unsigned / signed 16-bit fixed point, big endian,
    ///   with Y (hex digit) fraction bits, e.g. `sp78`, `fpe2`.
    /// - `ioft`: unsigned 64-bit, little endian, 16 fraction bits (48.16 fixed point).
    /// - `flag`: 0 / 1.
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        func bigEndian(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(0) { $0 << 8 | UInt64($1) }
        }

        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ": return bigEndian(1).map { Double($0) }
        case "ui16": return bigEndian(2).map { Double($0) }
        case "ui32": return bigEndian(4).map { Double($0) }
        case "ui64": return bigEndian(8).map { Double($0) }
        case "si8 ": return bigEndian(1).map { Double(Int8(truncatingIfNeeded: $0)) }
        case "si16": return bigEndian(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "si32": return bigEndian(4).map { Double(Int32(truncatingIfNeeded: $0)) }
        case "si64": return bigEndian(8).map { Double(Int64(bitPattern: $0)) }
        case "ioft":
            guard bytes.count >= 8 else { return nil }
            let raw = bytes.prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            return Double(raw) / 65536
        case "flag": return bytes.first.map { Double($0 != 0 ? 1 : 0) }
        default:
            break
        }

        let chars = Array(type)
        guard chars.count == 4, chars[0] == "f" || chars[0] == "s", chars[1] == "p",
              let fraction = chars[3].hexDigitValue, chars[2].hexDigitValue != nil,
              let raw = bigEndian(2) else {
            return nil
        }
        let divisor = Double(1 << fraction)
        if chars[0] == "s" {
            return Double(Int16(truncatingIfNeeded: raw)) / divisor
        }
        return Double(raw) / divisor
    }
}

public enum SMCError: Error, CustomStringConvertible {
    case unavailable(kern_return_t)
    case readFailed(FourCC, kern_return_t)

    public var description: String {
        switch self {
        case .unavailable(let kr): return "AppleSMC not available (kern_return \(kr))"
        case .readFailed(let key, let kr): return "reading SMC key \(key) failed (kern_return \(kr))"
        }
    }
}

/// Read-only connection to the AppleSMC.
///
/// This type exposes no way to write keys; the underlying C shim rejects any
/// command other than key info, read bytes and read index.
public final class SMC {
    private let connection: io_connect_t

    public init() throws {
        var connection: io_connect_t = 0
        let kr = FSSMCOpen(&connection)
        guard kr == KERN_SUCCESS else { throw SMCError.unavailable(kr) }
        self.connection = connection
    }

    deinit {
        FSSMCClose(connection)
    }

    public func read(_ key: FourCC) throws -> SMCValue {
        var buffer = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        var type: UInt32 = 0
        let kr = FSSMCReadKey(connection, key.rawValue, &buffer, &size, &type)
        guard kr == KERN_SUCCESS else { throw SMCError.readFailed(key, kr) }
        return SMCValue(key: key, type: FourCC(rawValue: type), bytes: Array(buffer.prefix(Int(size))))
    }

    public func read(_ key: String) throws -> SMCValue {
        try read(FourCC(key))
    }

    /// Number of keys reported by `#KEY`.
    public func keyCount() throws -> Int {
        Int(try read("#KEY").doubleValue ?? 0)
    }

    /// All keys, in SMC index order.
    public func allKeys() throws -> [FourCC] {
        let count = try keyCount()
        var keys: [FourCC] = []
        keys.reserveCapacity(count)
        for index in 0..<count {
            var raw: UInt32 = 0
            if FSSMCKeyAtIndex(connection, UInt32(index), &raw) == KERN_SUCCESS {
                keys.append(FourCC(rawValue: raw))
            }
        }
        return keys
    }
}
