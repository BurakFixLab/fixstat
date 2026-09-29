import CMacSensors
import Foundation
import IOKit

/// NVMe SMART / Health Information (NVMe base specification, log page 02h).
public struct NVMeHealth: Codable, Sendable, Equatable {
    /// Bit field: 0 spare below threshold, 1 temperature, 2 reliability degraded,
    /// 3 read-only, 4 volatile backup failed.
    public var criticalWarning: Int
    /// °C (composite temperature).
    public var temperature: Double?
    /// Available spare in %.
    public var availableSpare: Int
    public var availableSpareThreshold: Int
    /// Vendor estimate of life used in % (can exceed 100).
    public var percentageUsed: Int
    /// Bytes (data units × 512 000).
    public var bytesRead: Double
    public var bytesWritten: Double
    public var powerCycles: Double
    public var powerOnHours: Double
    public var unsafeShutdowns: Double
    public var mediaErrors: Double
    public var errorLogEntries: Double

    public static func parse(_ log: [UInt8]) -> NVMeHealth? {
        guard log.count >= 512 else { return nil }
        /// Little-endian 128-bit counter, as Double (exact up to 2^53).
        func counter(_ offset: Int) -> Double {
            var value = 0.0
            for index in (0..<16).reversed() { value = value * 256 + Double(log[offset + index]) }
            return value
        }
        let kelvin = Int(log[1]) | Int(log[2]) << 8
        return NVMeHealth(
            criticalWarning: Int(log[0]),
            temperature: kelvin > 0 ? Double(kelvin) - 273.15 : nil,
            availableSpare: Int(log[3]),
            availableSpareThreshold: Int(log[4]),
            percentageUsed: Int(log[5]),
            bytesRead: counter(32) * 512_000,
            bytesWritten: counter(48) * 512_000,
            powerCycles: counter(112),
            powerOnHours: counter(128),
            unsafeShutdowns: counter(144),
            mediaErrors: counter(160),
            errorLogEntries: counter(176)
        )
    }

    public var warnings: [String] {
        let names = ["spareBelowThreshold", "temperature", "reliabilityDegraded", "readOnly", "volatileBackupFailed"]
        return names.enumerated().compactMap { criticalWarning & (1 << $0.offset) != 0 ? $0.element : nil }
    }
}

/// Internal SSD identity from the IORegistry. The serial number is masked unless requested.
public struct SSDInfo: Codable, Sendable, Equatable {
    public var model: String?
    public var firmware: String?
    /// Bytes.
    public var capacity: Double?
    public var nandVendor: String?
    public var nandType: String?
    public var bitsPerCell: Int?
    public var serial: String?
    public var health: NVMeHealth?

    public static func read(includeSerial: Bool = false) -> SSDInfo? {
        var info = SSDInfo()
        if let controller = Registry.properties(ofClass: "IONVMeController") {
            info.model = (controller.string("Model Number"))?.trimmingCharacters(in: .whitespaces)
            info.firmware = (controller.string("Firmware Revision"))?.trimmingCharacters(in: .whitespaces)
            if let characteristics = controller.dict("Controller Characteristics") {
                info.capacity = (characteristics["capacity"] as? NSNumber)?.doubleValue
                info.nandVendor = characteristics.string("vendor-name")?.trimmingCharacters(in: .whitespaces)
                info.nandType = characteristics.string("nand-marketing-name")?.trimmingCharacters(in: .whitespaces)
                info.bitsPerCell = characteristics.int("default-bits-per-cell")
            }
            if let serial = controller.string("Serial Number")?.trimmingCharacters(in: .whitespaces), !serial.isEmpty {
                info.serial = includeSerial ? serial : Privacy.mask(serial)
            }
        }
        info.health = readHealth()
        guard info.model != nil || info.health != nil else { return nil }
        return info
    }

    public static func readHealth() -> NVMeHealth? {
        var log = [UInt8](repeating: 0, count: 512)
        guard FSNVMeReadSMARTLog(&log) == KERN_SUCCESS else { return nil }
        return NVMeHealth.parse(log)
    }
}
