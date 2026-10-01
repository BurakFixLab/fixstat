import Foundation

/// A decoded SMC key.
public struct SMCReading: Codable, Sendable, Equatable {
    public let key: String
    public let type: String
    public let value: Double?
    public let hex: String
}

/// A fan as reported by the SMC (`FNum`, `F<n>Ac` …).
public struct FanReading: Codable, Sendable, Equatable {
    public let index: Int
    /// rpm
    public let actual: Double?
    public let minimum: Double?
    public let maximum: Double?
    public let target: Double?
}

public extension SMC {
    /// Plausible range for a temperature reading in °C. SMC keys outside of it
    /// are usually unpopulated or not temperatures at all.
    static let plausibleTemperatureRange = 0.5...130.0

    /// Apple Silicon CPU / GPU die zones (SMC keys) read 0 or a constant calibration offset
    /// (≈ 5–10 °C) while their cluster is power gated. A die in use is never this cold.
    static let minimumActiveDieTemperature = 15.0

    /// Every key starting with `T` that decodes to a number.
    func temperatureReadings(keys: [FourCC]? = nil) -> [SMCReading] {
        let keys = (try? keys ?? allKeys()) ?? []
        return keys
            .filter { $0.description.hasPrefix("T") }
            .compactMap { key -> SMCReading? in
                guard let value = try? read(key), let number = value.doubleValue else { return nil }
                return SMCReading(key: key.description, type: value.type.description,
                                  value: number, hex: value.hexString)
            }
    }

    /// Every key with its decoded value (nil for non-numeric types).
    func allReadings(keys: [FourCC]? = nil) -> [SMCReading] {
        let keys = (try? keys ?? allKeys()) ?? []
        return keys.compactMap { key -> SMCReading? in
            guard let value = try? read(key) else { return nil }
            return SMCReading(key: key.description, type: value.type.description,
                              value: value.doubleValue, hex: value.hexString)
        }
    }

    /// Fans reported by `FNum`. Empty on fanless Macs.
    func fans() -> [FanReading] {
        guard let count = try? read("FNum").doubleValue, count > 0 else { return [] }
        return (0..<Int(count)).map { i in
            func value(_ suffix: String) -> Double? {
                (try? read("F\(i)\(suffix)"))?.doubleValue
            }
            return FanReading(index: i, actual: value("Ac"), minimum: value("Mn"),
                              maximum: value("Mx"), target: value("Tg"))
        }
    }
}
