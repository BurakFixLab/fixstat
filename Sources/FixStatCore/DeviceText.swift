import Foundation
import MacSensors

public enum DeviceText {
    public static func configuration(_ info: DeviceInfo, ssd: SSDInfo?) -> [(String, String)] {
        var rows: [(String, String)] = [(L("Chip"), info.system.chip)]
        if let p = info.performanceCores, let e = info.efficiencyCores {
            rows.append((L("CPU cores"),
                         L("%lld (%lld performance, %lld efficiency)", p + e, p, e)))
        }
        if let gpu = info.gpuCores { rows.append((L("GPU cores"), Format.number(Double(gpu)))) }
        if let memory = info.memoryBytes { rows.append((L("Memory"), Format.memory(memory))) }
        if let ssd {
            rows.append((L("SSD"), [ssd.capacity.map { Format.bytes($0) }, ssd.model]
                .compactMap { $0 }.joined(separator: " · ")))
        }
        if let firmware = info.firmwareVersion { rows.append((L("Firmware (iBoot)"), firmware)) }
        rows.append((L("macOS"), info.system.osVersion))
        return rows
    }

    /// (title, value, needs attention)
    public static func security(_ info: DeviceInfo) -> [(String, String, Bool)] {
        [
            (L("Activation Lock (Find My)"), state(info.activationLock,
                on: L("On — the owner must turn it off"), off: L("Off")),
             info.activationLock == .on),
            (L("MDM enrollment"), state(info.mdmEnrolled,
                on: L("Enrolled — managed by an organisation"), off: L("Not enrolled")),
             info.mdmEnrolled == .on),
            (L("Automated enrollment (DEP)"), state(info.depEnrolled,
                on: L("Yes"), off: L("No")), info.depEnrolled == .on),
            (L("System Integrity Protection"), state(info.sipEnabled,
                on: L("On"), off: L("Off — modified system")), info.sipEnabled == .off),
            (L("FileVault"), state(info.fileVault,
                on: L("On — the user password is needed to reach the data"), off: L("Off")),
             false),
        ]
    }

    public static func state(_ s: DeviceInfo.SecurityState, on: String, off: String) -> String {
        switch s {
        case .on: on
        case .off: off
        case .unknown: L("unknown")
        }
    }

    /// For pasting into a work order.
    public static func plainText(_ info: DeviceInfo, ssd: SSDInfo?, health: [(String, String, Bool)]) -> String {
        var lines = [info.system.marketingName ?? info.system.model,
                     [info.system.model, info.system.boardTarget, info.partNumber].compactMap { $0 }.joined(separator: " · ")]
        if let serial = info.serial { lines.append(L("Serial %@", serial)) }
        lines.append("")
        lines += configuration(info, ssd: ssd).map { "\($0.0): \($0.1)" }
        lines.append("")
        lines += security(info).map { "\($0.0): \($0.1)" }
        lines.append("")
        lines += health.map { "\($0.0): \($0.1)" }
        return lines.joined(separator: "\n")
    }
}
