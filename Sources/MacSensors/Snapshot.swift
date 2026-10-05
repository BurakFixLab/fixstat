import Foundation

/// Everything `sensordump` collects in one run.
public struct SensorSnapshot: Encodable, Sendable {
    public var tool = "sensordump"
    public var version = MacSensors.version
    public var timestamp: Date
    public var system: SystemInfo
    public var battery: BatteryInfo?
    /// Internal SSD identity and NVMe SMART health.
    public var ssd: SSDInfo?
    /// IOHIDEventSystem temperature sensors (°C).
    public var hidTemperatures: [HIDReading]
    /// IOHIDEventSystem voltage sensors (raw, unverified), only when requested.
    public var hidVoltages: [HIDReading]?
    /// IOHIDEventSystem current sensors (raw, unverified), only when requested.
    public var hidCurrents: [HIDReading]?
    /// SMC keys starting with `T`.
    public var smcTemperatures: [SMCReading]
    public var fans: [FanReading]
    /// All SMC keys, only when requested.
    public var smcAllKeys: [SMCReading]?
    /// Masked raw `AppleSmartBattery` registry properties, only when requested.
    public var batteryRaw: JSONValue?
    /// Problems encountered while reading (e.g. SMC not accessible).
    public var errors: [String]
}

public enum MacSensors {
    public static let version = "1.2.0" // keep in sync with CFBundleShortVersionString

    public struct Options: Sendable {
        public var includeSerial = false
        public var includeRawBattery = false
        public var includeAllSMCKeys = false
        public var includeHIDPower = false

        public init() {}
    }

    public static func snapshot(options: Options) -> SensorSnapshot {
        var errors: [String] = []

        let battery = BatteryReader.read(includeSerial: options.includeSerial)
        var batteryRaw: JSONValue?
        if options.includeRawBattery, let props = BatteryReader.rawProperties() {
            let tree = JSONValue(propertyList: props)
            batteryRaw = options.includeSerial ? tree : Privacy.maskTree(tree)
        }

        let hidTemperatures = HIDSensorReader(kind: .temperature)?.read() ?? []
        let hidVoltages = options.includeHIDPower ? HIDSensorReader(kind: .voltage)?.read() ?? [] : nil
        let hidCurrents = options.includeHIDPower ? HIDSensorReader(kind: .current)?.read() ?? [] : nil

        var smcTemperatures: [SMCReading] = []
        var fans: [FanReading] = []
        var smcAll: [SMCReading]?
        do {
            let smc = try SMC()
            let keys = try smc.allKeys()
            smcTemperatures = smc.temperatureReadings(keys: keys)
            fans = smc.fans()
            if options.includeAllSMCKeys {
                smcAll = smc.allReadings(keys: keys)
            }
        } catch {
            errors.append(String(describing: error))
        }

        return SensorSnapshot(
            timestamp: Date(),
            system: .current(),
            battery: battery,
            ssd: SSDInfo.read(includeSerial: options.includeSerial),
            hidTemperatures: hidTemperatures,
            hidVoltages: hidVoltages,
            hidCurrents: hidCurrents,
            smcTemperatures: smcTemperatures,
            fans: fans,
            smcAllKeys: smcAll,
            batteryRaw: batteryRaw,
            errors: errors
        )
    }
}
