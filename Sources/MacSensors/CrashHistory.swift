import Foundation

/// A kernel panic report from DiagnosticReports.
public struct PanicReport: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(date.timeIntervalSince1970)-\(summary.hashValue)" }
    public let date: Date
    /// First line of the panic string, e.g. "panic(cpu 4 caller 0x…): SMC PANIC - …".
    public let summary: String
    /// Full panic string as written by the kernel.
    public let panicString: String
    /// "Panicked task …: pid N: name" if present.
    public let panickedProcess: String?
    /// Best guess of the affected area (see `PanicReport.areas`).
    public let area: String?

    /// Keyword → area, checked in order. Hints only; the panic string is authoritative.
    public static let areas: [(keyword: String, area: String)] = [
        ("SMC PANIC", "smc"), ("AppleSMC", "smc"),
        ("AOP PANIC", "aop"), ("AOP", "aop"),
        ("thermalmonitord", "thermal"),
        ("Sleep transition timed out", "sleepwake"), ("sleep wake", "sleepwake"),
        ("watchdog timeout", "watchdog"), ("WDT", "watchdog"),
        ("ANS2", "ssd"), ("AppleANS", "ssd"), ("NVMe", "ssd"),
        ("DCP", "display"), ("AppleDisplay", "display"),
        ("AGX", "gpu"), ("GPU", "gpu"),
        ("i2c", "i2c"), ("I2C", "i2c"),
        ("PMU", "power"), ("AppleSPMI", "power"),
        ("USB", "usb"), ("AppleT8103TypeC", "usb"), ("HPM", "usb"),
        ("Bluetooth", "wireless"), ("AppleBCMWLAN", "wireless"),
    ]

    public static func area(for text: String) -> String? {
        areas.first { text.contains($0.keyword) }?.area
    }

    /// Parses a `.panic` / `.ips` file: a one-line JSON header followed by a JSON
    /// body with `panicString` (Apple Silicon) or `macOSPanicString`.
    public static func parse(_ text: String, fileDate: Date) -> PanicReport? {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first else { return nil }
        let header = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any]
        let bugType = header?["bug_type"] as? String
        guard bugType == nil || bugType == "210" || bugType == "288" else { return nil }
        var body: [String: Any] = [:]
        if parts.count > 1, let object = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] {
            body = object
        }
        guard let panic = (body["panicString"] ?? body["macOSPanicString"]) as? String, !panic.isEmpty else { return nil }

        var date = fileDate
        if let stamp = (header?["timestamp"] ?? body["date"]) as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd HH:mm:ss.SS Z", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd HH:mm:ss.SSSSSS Z"] {
                formatter.dateFormat = format
                if let parsed = formatter.date(from: stamp) { date = parsed; break }
            }
        }
        let lines = panic.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        let summary = lines.first { !$0.isEmpty } ?? panic
        let process = lines.first { $0.hasPrefix("Panicked task") }
            .map { line in line.components(separatedBy: ": ").dropFirst().joined(separator: ": ") }
        return PanicReport(date: date, summary: summary, panicString: panic,
                           panickedProcess: process, area: area(for: summary) ?? area(for: panic))
    }
}

/// A "Previous shutdown cause" entry from the unified log.
public struct ShutdownEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: Double { date.timeIntervalSince1970 }
    public let date: Date
    public let code: Int

    /// Meaning of common codes as documented by the repair community. Not
    /// official; exact meanings can differ between models.
    public static let meanings: [Int: String] = [
        5: "normal", 3: "hardShutdown", 0: "powerLoss", -3: "overTemperature",
        -60: "batteryEmpty", -61: "smcWatchdog", -62: "watchdog", -71: "memoryTemperature",
        -74: "batteryTemperature", -75: "adapterCommunication", -78: "adapterCurrent",
        -79: "batteryCurrent", -86: "proximityTemperature", -95: "cpuTemperature",
        -100: "powerSupplyTemperature", -103: "batteryCellVoltage", -104: "battery",
        -127: "pmuForced", -128: "unknownCritical",
    ]

    public var meaning: String? { Self.meanings[code] }
    /// 5 (normal) and 3 (power button held) are not faults.
    public var isFault: Bool { code != 5 && code != 3 }

    /// Parses `log show --style ndjson` output.
    public static func parse(ndjson: String) -> [ShutdownEvent] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        let regex = try! NSRegularExpression(pattern: "Previous shutdown cause:\\s*(-?\\d+)")
        return ndjson.split(separator: "\n").compactMap { line -> ShutdownEvent? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
                  let range = Range(match.range(at: 1), in: message),
                  let code = Int(message[range]) else { return nil }
            let stamp = object["timestamp"] as? String ?? ""
            return ShutdownEvent(date: formatter.date(from: stamp) ?? Date.distantPast, code: code)
        }
    }
}

public enum CrashHistory {
    public static let reportDirectories = [
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports"),
        URL(fileURLWithPath: "/Library/Logs/DiagnosticReports/Retired"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
    ]

    /// All readable panic reports, newest first. File names (which contain the
    /// computer name) are not kept.
    public static func panics(in directories: [URL] = reportDirectories) -> [PanicReport] {
        var reports: [PanicReport] = []
        for directory in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".panic") || (name.hasSuffix(".ips") && name.lowercased().contains("panic"))
                || (name.hasPrefix("Kernel") && name.hasSuffix(".ips")) {
                let url = directory.appendingPathComponent(name)
                guard let data = FileManager.default.contents(atPath: url.path),
                      let text = String(data: data, encoding: .utf8) else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                if let report = PanicReport.parse(text, fileDate: modified) { reports.append(report) }
            }
        }
        var seen = Set<String>()
        return reports
            .filter { seen.insert("\($0.date.timeIntervalSince1970)|\($0.summary)").inserted }
            .sorted { $0.date > $1.date }
    }

    /// Shutdown causes from the unified log over the last `days` days (slow: runs `log show`).
    public static func shutdownEvents(days: Int = 30) -> [ShutdownEvent] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--last", "\(days)d", "--style", "ndjson",
                             "--predicate", "eventMessage CONTAINS \"Previous shutdown cause\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ShutdownEvent.parse(ndjson: String(decoding: data, as: UTF8.self)).sorted { $0.date > $1.date }
    }
}
