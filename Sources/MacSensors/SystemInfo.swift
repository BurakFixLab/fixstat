import Foundation

/// Identification of the Mac. Contains no serial numbers or UUIDs.
public struct SystemInfo: Codable, Sendable, Equatable {
    /// e.g. "MacBookAir10,1"
    public var model: String
    /// Board target, e.g. "J313" (Apple Silicon device tree `target-type`).
    public var boardTarget: String?
    /// e.g. "Apple M1"
    public var chip: String
    /// "arm64" or "x86_64"
    public var architecture: String
    public var isAppleSilicon: Bool
    /// e.g. "26.6.2 (25G83)"
    public var osVersion: String

    public static func current() -> SystemInfo {
        let arch = sysctlString("hw.machine") ?? "unknown"
        let translated = sysctlInt("sysctl.proc_translated") == 1
        let appleSilicon = arch == "arm64" || translated
        return SystemInfo(
            model: sysctlString("hw.model") ?? "unknown",
            boardTarget: Registry.platformString("target-type"),
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            architecture: arch,
            isAppleSilicon: appleSilicon,
            osVersion: osVersionString()
        )
    }

    static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var version = "\(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { version += ".\(v.patchVersion)" }
        if let build = sysctlString("kern.osversion") { version += " (\(build))" }
        return version
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
