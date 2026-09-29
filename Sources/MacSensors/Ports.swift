import Foundation
import IOKit

/// A built-in USB-C / MagSafe port as seen by the port controller (`IOPort`,
/// e.g. "Port-USB-C@1"), with the USB devices attached below it.
///
/// Read-only IORegistry properties; no root needed. Available on Apple Silicon
/// (and on macOS versions that publish `IOPort` services).
public struct PortStatus: Codable, Sendable, Equatable, Identifiable {
    /// "USB-C", "MagSafe 3", …
    public var type: String
    public var number: Int
    /// Something is plugged in (CC detected a partner).
    public var connected: Bool
    /// Transports currently active, e.g. `["CC", "USB3"]`, `["CC", "CIO"]`.
    public var activeTransports: [String]
    public var supportedTransports: [String]
    /// The port is charging the Mac.
    public var powerIn: Bool?
    public var overcurrentCount: Int?
    /// Plug-in count since boot.
    public var connectionCount: Int?
    /// USB enumeration failures since boot, summed over the port's USB 2 and USB 3 lanes.
    public var enumerationFailures: Int?
    /// USB-PD port controller counters (Apple Silicon `PortControllerInfo`).
    public var controller: PortControllerCounters?
    public var devices: [USBDeviceInfo]

    public var id: String { "\(type)@\(number)" }

    public init(type: String, number: Int, connected: Bool, activeTransports: [String], supportedTransports: [String],
                powerIn: Bool?, overcurrentCount: Int?, connectionCount: Int?, enumerationFailures: Int?,
                controller: PortControllerCounters? = nil, devices: [USBDeviceInfo]) {
        self.type = type
        self.number = number
        self.connected = connected
        self.activeTransports = activeTransports
        self.supportedTransports = supportedTransports
        self.powerIn = powerIn
        self.overcurrentCount = overcurrentCount
        self.connectionCount = connectionCount
        self.enumerationFailures = enumerationFailures
        self.controller = controller
        self.devices = devices
    }
}

/// Fault counters of a USB-C port controller since boot.
public struct PortControllerCounters: Codable, Sendable, Equatable {
    /// A power contract is active on this port (it charges the Mac).
    public var charging: Bool
    public var maxPowerWatts: Double?
    public var shortDetect: Int
    public var hardReset: Int
    /// The input power FET failed to switch on.
    public var inputFETFailures: Int
    public var i2cErrors: Int

    public init(charging: Bool, maxPowerWatts: Double?, shortDetect: Int, hardReset: Int, inputFETFailures: Int, i2cErrors: Int) {
        self.charging = charging
        self.maxPowerWatts = maxPowerWatts
        self.shortDetect = shortDetect
        self.hardReset = hardReset
        self.inputFETFailures = inputFETFailures
        self.i2cErrors = i2cErrors
    }

    public var hasFaults: Bool { shortDetect + hardReset + inputFETFailures + i2cErrors > 0 }

    /// One `PortControllerInfo` entry. `externalPower` is AppleSmartBattery's `ExternalConnected`.
    static func parse(_ p: [String: Any], externalPower: Bool) -> PortControllerCounters {
        let rdo = p.int("PortControllerActiveContractRdo") ?? 0
        let maxPower = p.int("PortControllerMaxPower") ?? 0 // mW
        return PortControllerCounters(
            charging: externalPower && (rdo != 0 || maxPower > 0),
            maxPowerWatts: maxPower > 0 ? Double(maxPower) / 1000 : nil,
            shortDetect: p.int("PortControllerShortDetectCount") ?? 0,
            hardReset: p.int("PortControllerHardResetCount") ?? 0,
            inputFETFailures: p.int("PortControllerInpFetEnFailCount") ?? 0,
            i2cErrors: p.int("PortControllerI2cErrCount") ?? 0)
    }
}

/// A USB device (no serial number is read).
public struct USBDeviceInfo: Codable, Sendable, Equatable {
    public var name: String?
    public var vendorID: Int?
    public var productID: Int?
    /// IOUSBHostDevice "Device Speed": 0 low, 1 full, 2 high, 3 super, 4 super+ (10 Gb/s), 5 super+ 2×2.
    public var speed: Int?
    /// Built-in USB-C port number, if the device hangs off one.
    public var portNumber: Int?

    public init(name: String?, vendorID: Int?, productID: Int?, speed: Int?, portNumber: Int?) {
        self.name = name
        self.vendorID = vendorID
        self.productID = productID
        self.speed = speed
        self.portNumber = portNumber
    }

    /// Nominal signalling rate in Mb/s.
    public var megabitsPerSecond: Int? {
        switch speed {
        case 0: 1 // 1.5 Mb/s, rounded
        case 1: 12
        case 2: 480
        case 3: 5_000
        case 4: 10_000
        case 5: 20_000
        default: nil
        }
    }
}

public enum PortReader {
    public static func read() -> [PortStatus] {
        let devices = usbDevices()
        let failures = enumerationFailures()
        let power = powerInPorts()
        let controllers = portControllers()
        var ports: [PortStatus] = []
        forEachService(matching: "IOPort") { _, p in
            guard p.bool("BuiltIn") != false,
                  let type = p.string("PortTypeDescription"), let number = p.int("PortNumber") else { return }
            let isUSBC = type == "USB-C"
            // PortControllerInfo is ordered by USB-C port number.
            let controller = isUSBC && number >= 1 && number <= controllers.count ? controllers[number - 1] : nil
            let powerIn: Bool? = switch (power["\(type)@\(number)"], controller?.charging) {
            case (nil, nil): nil
            case let (a, b): (a ?? false) || (b ?? false)
            }
            ports.append(PortStatus(
                type: type, number: number,
                connected: p.bool("ConnectionActive") ?? false,
                activeTransports: p["TransportsActive"] as? [String] ?? [],
                supportedTransports: p["TransportsSupported"] as? [String] ?? [],
                powerIn: powerIn,
                overcurrentCount: p.int("Overcurrent Count"),
                connectionCount: p.int("ConnectionCount"),
                enumerationFailures: isUSBC ? failures[number] : nil,
                controller: controller,
                devices: isUSBC ? devices.filter { $0.portNumber == number } : []
            ))
        }
        return ports.sorted { ($0.type, $0.number) < ($1.type, $1.number) }
    }

    /// USB devices that are not internal (keyboard/trackpad and hubs inside the Mac
    /// are not below a USB-C port, so they have no port number).
    public static func usbDevices() -> [USBDeviceInfo] {
        var result: [USBDeviceInfo] = []
        forEachService(matching: "IOUSBHostDevice") { service, p in
            result.append(USBDeviceInfo(
                name: p.string("USB Product Name") ?? p.string("kUSBProductString"),
                vendorID: p.int("idVendor"), productID: p.int("idProduct"),
                speed: p.int("Device Speed"), portNumber: usbCPortNumber(above: service)))
        }
        return result
    }

    /// `PortControllerInfo` of AppleSmartBattery (Apple Silicon), one entry per USB-C port.
    static func portControllers() -> [PortControllerCounters] {
        guard let battery = Registry.properties(ofClass: "AppleSmartBattery"),
              let list = battery["PortControllerInfo"] as? [[String: Any]] else { return [] }
        let external = battery.bool("ExternalConnected") ?? false
        return list.map { PortControllerCounters.parse($0, externalPower: external) }
    }

    /// `ParentBuiltInPortNumber` → Active of `IOPortFeaturePowerIn`, keyed "USB-C@1".
    /// (Stayed false while charging on macOS 26 / M1; the port controller is checked too.)
    static func powerInPorts() -> [String: Bool] {
        var result: [String: Bool] = [:]
        forEachService(matching: "IOPortFeaturePowerIn") { _, p in
            guard let type = p.string("ParentPortTypeDescription"),
                  let number = p.int("ParentBuiltInPortNumber") ?? p.int("ParentPortNumber") else { return }
            result["\(type)@\(number)"] = p.bool("Active")
        }
        return result
    }

    /// Enumeration failures per USB-C port from the XHCI root hub ports' statistics.
    static func enumerationFailures() -> [Int: Int] {
        var result: [Int: Int] = [:]
        forEachService(matching: "AppleUSBHostPort") { _, p in
            guard let number = p.int("UsbCPortNumber"),
                  let stats = p.dict("port-statistics"),
                  let failures = stats.int("kPortStatEnumerationFailureCount") else { return }
            result[number, default: 0] += failures
        }
        return result
    }

    /// Walks up the service plane until an XHCI port with `UsbCPortNumber`.
    static func usbCPortNumber(above service: io_registry_entry_t) -> Int? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<12 {
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
            IOObjectRelease(current)
            current = parent
            if let value = IORegistryEntryCreateCFProperty(current, "UsbCPortNumber" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return value.intValue
            }
        }
        return nil
    }

    static func forEachService(matching className: String, _ body: (io_registry_entry_t, [String: Any]) -> Void) {
        var iterator: io_iterator_t = IO_OBJECT_NULL
        guard IOServiceGetMatchingServices(ioMainPort, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            if let properties = Registry.properties(of: service) { body(service, properties) }
            IOObjectRelease(service)
        }
    }
}

/// Lid (clamshell) state from the power management root domain.
public enum LidSensor {
    /// `AppleClamshellState`: true while the lid is closed. nil on desktops.
    public static func isClosed() -> Bool? {
        guard let value = Registry.properties(ofClass: "IOPMrootDomain")?["AppleClamshellState"] as? NSNumber
        else { return nil }
        return value.boolValue
    }

    /// Reason of the most recent sleep in `pmset -g log`, e.g. "Clamshell Sleep".
    public static func lastSleepReason(within seconds: TimeInterval, now: Date = Date()) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseLastSleepReason(String(decoding: data, as: UTF8.self), within: seconds, now: now)
    }

    /// Finds the last "Sleep … Entering Sleep state due to '<reason>'" line not older
    /// than `seconds`.
    static func parseLastSleepReason(_ log: String, within seconds: TimeInterval, now: Date) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        for line in log.split(separator: "\n").reversed() {
            guard line.contains("Entering Sleep state due to '"), line.count > 25,
                  let date = formatter.date(from: String(line.prefix(25))) else { continue }
            guard now.timeIntervalSince(date) <= seconds else { return nil }
            guard let start = line.range(of: "due to '")?.upperBound,
                  let end = line[start...].firstIndex(of: "'") else { return nil }
            return String(line[start..<end])
        }
        return nil
    }
}
