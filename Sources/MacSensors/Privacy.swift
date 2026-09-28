import Foundation

/// Masking of identifying values (serial numbers, UUIDs) in all outputs.
public enum Privacy {
    /// Registry keys whose values are treated as identifying.
    public static func isSensitiveKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.contains("serial") || lower.contains("uuid")
    }

    /// Keeps the first three characters (vendor prefix, useful for identifying
    /// the cell/pack manufacturer) and replaces the rest with `*`.
    public static func mask(_ value: String) -> String {
        let keep = value.count > 6 ? 3 : 0
        return String(value.prefix(keep)) + String(repeating: "*", count: max(value.count - keep, 1))
    }

    /// Recursively masks sensitive keys in a property list-like structure.
    public static func maskTree(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let dict):
            var result: [String: JSONValue] = [:]
            for (key, child) in dict {
                if isSensitiveKey(key) {
                    result[key] = maskLeaf(child)
                } else {
                    result[key] = maskTree(child)
                }
            }
            return .object(result)
        case .array(let items):
            return .array(items.map(maskTree))
        default:
            return value
        }
    }

    private static func maskLeaf(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s): return .string(mask(s))
        case .number, .bool, .null: return .string("***")
        case .object, .array: return .string("***")
        }
    }
}
