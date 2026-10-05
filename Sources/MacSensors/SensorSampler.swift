import Foundation

/// Identifies one temperature sensor independent of how it is read.
public struct SensorDescriptor: Codable, Sendable, Hashable {
    public enum Source: String, Codable, Sendable {
        case hid
        case smc
    }

    public let source: Source
    /// SMC key (for HID sensors: the service LocationID as FourCC), if known.
    public let key: String?
    /// HID Product name; nil for SMC-only sensors.
    public let hidName: String?

    /// Stable identifier within one machine, e.g. "hid:Tp2i" or "smc:TCHP".
    public var uid: String {
        "\(source.rawValue):\(key ?? hidName ?? "?")"
    }

    /// The raw label shown to users: the SMC key, or the HID name if there is no key.
    public var rawLabel: String {
        key ?? hidName ?? "?"
    }
}

/// Reads all temperature sensors (HID + SMC `T*` keys) repeatedly.
///
/// HID sensors come first. SMC keys that are also exposed through HID (same
/// key) are skipped, so each physical sensor appears once.
public final class TemperatureSampler {
    public private(set) var sensors: [SensorDescriptor] = []
    private let hid: HIDSensorReader?
    private let smc: SMC?
    private var smcKeys: [FourCC] = []

    /// - Parameter includeSMCKey: filter for SMC keys to sample; HID sensors are
    ///   always included (they are read in one call anyway).
    public init(includeSMCKey: (String) -> Bool = { _ in true }) {
        hid = HIDSensorReader(kind: .temperature)
        smc = try? SMC()

        let hidReadings = hid?.read() ?? []
        var seen = Set<String>()
        for reading in hidReadings {
            let descriptor = SensorDescriptor(source: .hid, key: reading.key, hidName: reading.name)
            if seen.insert(descriptor.uid).inserted {
                sensors.append(descriptor)
            }
        }
        let hidKeys = Set(hidReadings.compactMap(\.key))
        if let smc, let keys = try? smc.allKeys() {
            let candidates = keys.filter { includeSMCKey($0.description) }
            for reading in smc.temperatureReadings(keys: candidates) where !hidKeys.contains(reading.key) {
                sensors.append(SensorDescriptor(source: .smc, key: reading.key, hidName: nil))
                smcKeys.append(FourCC(reading.key))
            }
        }
    }

    /// Fans via the same SMC connection (empty on fanless Macs).
    public func fans() -> [FanReading] {
        smc?.fans() ?? []
    }

    /// Total system power from the SMC (`PSTR`, W).
    public func systemPower() -> Double? {
        smc?.systemPower()
    }

    /// Only the HID sensors (one IPC call), keyed by uid. Cheaper than `sample()`.
    public func sampleHID() -> [String: Double] {
        var values: [String: Double] = [:]
        for reading in hid?.read() ?? [] {
            values[SensorDescriptor(source: .hid, key: reading.key, hidName: reading.name).uid] = reading.value
        }
        return values
    }

    /// Only the given SMC keys, keyed by uid. For the few keys needed while the panel is
    /// closed (CPU / GPU die sensors that are not exposed through HID).
    public func sampleSMC(keys: [String]) -> [String: Double] {
        guard let smc else { return [:] }
        var values: [String: Double] = [:]
        for key in keys {
            if let value = (try? smc.read(FourCC(key)))?.doubleValue {
                values[SensorDescriptor(source: .smc, key: key, hidName: nil).uid] = value
            }
        }
        return values
    }

    /// One value per entry of `sensors` (nil if the read failed).
    public func sample() -> [Double?] {
        var hidValues: [String: Double] = [:]
        for reading in hid?.read() ?? [] {
            let uid = SensorDescriptor(source: .hid, key: reading.key, hidName: reading.name).uid
            hidValues[uid] = reading.value
        }
        var smcValues: [String: Double] = [:]
        if let smc {
            for key in smcKeys {
                if let value = (try? smc.read(key))?.doubleValue {
                    smcValues[key.description] = value
                }
            }
        }
        return sensors.map { sensor in
            switch sensor.source {
            case .hid: hidValues[sensor.uid]
            case .smc: sensor.key.flatMap { smcValues[$0] }
            }
        }
    }
}
