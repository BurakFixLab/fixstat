import Foundation

/// Identity, configuration and ownership / security state of the Mac for the device card.
///
/// Everything is read without root: `system_profiler SPHardwareDataType`, `profiles`,
/// `csrutil`, `fdesetup`, sysctl and the IORegistry. The serial number is masked unless
/// `includeSerial` is set; the provisioning UDID and platform UUID are never read.
public struct DeviceInfo: Codable, Sendable, Equatable {
    public var system: SystemInfo
    /// Regional part number, e.g. "MGN63TU/A".
    public var partNumber: String?
    public var serial: String?
    public var performanceCores: Int?
    public var efficiencyCores: Int?
    public var gpuCores: Int?
    public var memoryBytes: UInt64?
    /// iBoot / boot ROM version, e.g. "18000.161.10".
    public var firmwareVersion: String?
    public var activationLock: SecurityState
    public var mdmEnrolled: SecurityState
    public var depEnrolled: SecurityState
    public var sipEnabled: SecurityState
    public var fileVault: SecurityState

    public enum SecurityState: String, Codable, Sendable {
        case on, off, unknown
    }

    public static func read(includeSerial: Bool = false) -> DeviceInfo {
        let hardware = hardwareOverview()
        let enrollment = Command.output("/usr/bin/profiles", ["status", "-type", "enrollment"])
        let serial = hardware?["serial_number"] as? String
        return DeviceInfo(
            system: .current(),
            partNumber: hardware?["model_number"] as? String,
            serial: serial.map { includeSerial ? $0 : Privacy.mask($0) },
            performanceCores: SystemInfo.sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: SystemInfo.sysctlInt("hw.perflevel1.physicalcpu"),
            gpuCores: Registry.properties(ofClass: "AGXAccelerator")?.int("gpu-core-count"),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            firmwareVersion: hardware?["boot_rom_version"] as? String,
            activationLock: activationLock(hardware?["activation_lock_status"] as? String),
            mdmEnrolled: parseEnrollment(enrollment, prefix: "MDM enrollment:"),
            depEnrolled: parseEnrollment(enrollment, prefix: "Enrolled via DEP:"),
            sipEnabled: parseStatus(Command.output("/usr/bin/csrutil", ["status"]), on: "enabled", off: "disabled"),
            fileVault: parseStatus(Command.output("/usr/bin/fdesetup", ["status"]), on: "FileVault is On",
                                   off: "FileVault is Off")
        )
    }

    static func hardwareOverview() -> [String: Any]? {
        guard let text = Command.output("/usr/sbin/system_profiler", ["SPHardwareDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        return (json["SPHardwareDataType"] as? [[String: Any]])?.first
    }

    static func activationLock(_ value: String?) -> SecurityState {
        switch value {
        case "activation_lock_enabled": .on
        case "activation_lock_disabled": .off
        default: .unknown
        }
    }

    /// `profiles status -type enrollment`: "Enrolled via DEP: No", "MDM enrollment: Yes (User Approved)".
    static func parseEnrollment(_ text: String?, prefix: String) -> SecurityState {
        guard let line = text?.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return .unknown }
        let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("Yes") { return .on }
        if value.hasPrefix("No") { return .off }
        return .unknown
    }

    static func parseStatus(_ text: String?, on: String, off: String) -> SecurityState {
        guard let text else { return .unknown }
        if text.contains(on) { return .on }
        if text.contains(off) { return .off }
        return .unknown
    }
}

/// Runs a system tool and returns its standard output (nil if it could not start).
public enum Command {
    /// `pmset -g log` (the power management log, about a week).
    public static func pmsetLog() -> String {
        output("/usr/bin/pmset", ["-g", "log"]) ?? ""
    }

    static func output(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
