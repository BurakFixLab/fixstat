import Foundation

/// A JSON-encodable representation of an arbitrary property list, used for
/// raw registry dumps. `Data` is encoded as a lower-case hex string.
public enum JSONValue: Encodable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(propertyList value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .number(number.doubleValue)
            } else {
                // Registry integers are signed 64-bit; negative values (e.g. Amperage)
                // show up as huge unsigned numbers in `ioreg`.
                self = .number(Double(number.int64Value))
            }
        case let string as String:
            self = .string(string)
        case let data as Data:
            self = .string(data.map { String(format: "%02x", $0) }.joined())
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(propertyList:)))
        case let dict as [String: Any]:
            self = .object(dict.mapValues(JSONValue.init(propertyList:)))
        default:
            self = .string(String(describing: value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 {
                try container.encode(Int64(n))
            } else {
                try container.encode(n)
            }
        case .bool(let b): try container.encode(b)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        case .null: try container.encodeNil()
        }
    }
}
