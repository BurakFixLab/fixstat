import Foundation

/// Sleep / wake behaviour from the power management log (`pmset -g log`, about a week
/// of history kept by macOS) and the current settings (`pmset -g`). No root needed.
///
/// Answers the usual complaints: "the battery is empty after a night asleep" (drain per
/// hour while asleep on battery), "it wakes up by itself" (wake and dark wake reasons),
/// "it does not go to sleep" (what prevents sleep) and slow or failed sleep / wake.
public struct SleepAnalysis: Codable, Sendable, Equatable {
    public struct Event: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case sleep, wake, darkWake, failure }
        public var date: Date
        public var kind: Kind
        /// Sleep: "Clamshell Sleep", "Idle Sleep", "Low Power Sleep" …; wake: "EC.LidOpen/Lid Open" …
        public var reason: String
        public var onBattery: Bool?
        /// Battery charge in % at that moment.
        public var charge: Int?
        /// Sleep: time asleep; dark wake: time awake (seconds).
        public var duration: Int?
    }

    public struct Count: Codable, Sendable, Equatable {
        public var name: String
        public var count: Int
    }

    public struct DriverDelay: Codable, Sendable, Equatable {
        public var driver: String
        public var count: Int
        public var maxMilliseconds: Int
    }

    public struct Preventer: Codable, Sendable, Equatable {
        public var process: String
        public var count: Int
        /// Longest single assertion (assertions overlap, so they are not summed).
        public var longestSeconds: Int
    }

    public var from: Date?
    public var to: Date?
    public var events: [Event]
    public var wakeTimes: [Double]
    public var slowDrivers: [DriverDelay]
    /// Processes that held sleep-preventing assertions, by their longest one (from the log).
    public var preventers: [Preventer]
    /// Low battery warnings (BatteryHealth "Warning level" lines).
    public var lowBatteryWarnings: Int
    /// Current `pmset -g` settings, e.g. "powernap": "1".
    public var settings: [String: String]
    /// Processes currently preventing sleep ("sleep prevented by …").
    public var preventingNow: [String]
    /// Periods the Mac was shut down, with the charge before and after (from the log).
    public var offPeriods: [OffPeriod] = []

    public var sleeps: [Event] { events.filter { $0.kind == .sleep } }
    public var wakes: [Event] { events.filter { $0.kind == .wake } }
    public var darkWakes: [Event] { events.filter { $0.kind == .darkWake } }
    public var failures: [Event] { events.filter { $0.kind == .failure } }
    /// Sleeps forced by an almost empty battery.
    public var lowPowerSleeps: Int { sleeps.filter { $0.reason.localizedCaseInsensitiveContains("low power") }.count }

    public var averageWakeTime: Double? {
        wakeTimes.isEmpty ? nil : wakeTimes.reduce(0, +) / Double(wakeTimes.count)
    }

    public func reasons(_ kind: Event.Kind, limit: Int = 5) -> [Count] {
        var counts: [String: Int] = [:]
        for e in events where e.kind == kind { counts[e.reason.isEmpty ? "?" : e.reason, default: 0] += 1 }
        return counts.map { Count(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(limit).map { $0 }
    }

    /// Battery drain while asleep on battery: charge lost between falling asleep and the
    /// next (dark) wake, over sleeps of at least 30 minutes that did not gain charge.
    public var sleepDrain: (percentPerHour: Double, hours: Double, segments: Int)? {
        var lost = 0.0
        var hours = 0.0
        var segments = 0
        for (index, event) in events.enumerated() where event.kind == .sleep && event.onBattery == true {
            guard let start = event.charge,
                  let next = events[(index + 1)...].first(where: { $0.kind == .wake || $0.kind == .darkWake }),
                  let end = next.charge, end <= start else { continue }
            let span = next.date.timeIntervalSince(event.date) / 3600
            guard span >= 0.5 else { continue }
            lost += Double(start - end)
            hours += span
            segments += 1
        }
        return hours > 0 ? (lost / hours, hours, segments) : nil
    }

    // MARK: Reading

    public static func read() -> SleepAnalysis {
        let log = Command.output("/usr/bin/pmset", ["-g", "log"]) ?? ""
        var analysis = parse(log: log)
        analysis.offPeriods = OffStateDrain.fromLog(log, records: OffStateDrain.bootRecords(),
                                                    fullChargeCapacity: BatteryReader.read()?.rawMaxCapacity)
        let current = parseSettings(Command.output("/usr/bin/pmset", ["-g"]) ?? "")
        analysis.settings = current.settings
        analysis.preventingNow = current.preventing
        return analysis
    }

    public static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    static let sleepPreventing: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]

    public static func parse(log: String) -> SleepAnalysis {
        var analysis = SleepAnalysis(from: nil, to: nil, events: [], wakeTimes: [], slowDrivers: [], preventers: [],
                                     lowBatteryWarnings: 0, settings: [:], preventingNow: [])
        var drivers: [String: DriverDelay] = [:]
        var preventers: [String: Preventer] = [:]
        for raw in log.split(separator: "\n") {
            let line = String(raw)
            guard line.count > 26, let date = dateFormatter.date(from: String(line.prefix(25))) else { continue }
            let rest = line.dropFirst(26)
            let domain: String
            let message: String
            if let tab = rest.firstIndex(of: "\t") {
                domain = rest[..<tab].trimmingCharacters(in: .whitespaces)
                message = rest[rest.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            } else {
                domain = String(rest.prefix(20)).trimmingCharacters(in: .whitespaces)
                message = String(rest.dropFirst(20)).trimmingCharacters(in: .whitespaces)
            }
            if analysis.from == nil { analysis.from = date }
            analysis.to = date

            switch domain {
            case "Sleep":
                guard message.contains("Entering Sleep") else { continue }
                analysis.events.append(Event(date: date, kind: .sleep, reason: quoted(message) ?? "",
                                             onBattery: onBattery(message), charge: charge(message),
                                             duration: trailingSeconds(message)))
            case "Wake", "DarkWake":
                guard message.contains("due to") else { continue }
                analysis.events.append(Event(date: date, kind: domain == "Wake" ? .wake : .darkWake,
                                             reason: wakeReason(message), onBattery: onBattery(message),
                                             charge: charge(message), duration: trailingSeconds(message)))
            case "Failure":
                analysis.events.append(Event(date: date, kind: .failure, reason: String(message.prefix(160))))
            case "WakeTime":
                if let value = message.split(separator: " ").compactMap({ Double($0) }).first {
                    analysis.wakeTimes.append(value)
                }
            case "Kernel Client Acks":
                for (driver, ms) in slowDrivers(message) {
                    var entry = drivers[driver] ?? DriverDelay(driver: driver, count: 0, maxMilliseconds: 0)
                    entry.count += 1
                    entry.maxMilliseconds = max(entry.maxMilliseconds, ms)
                    drivers[driver] = entry
                }
            case "Assertions":
                if let (process, type, seconds) = releasedAssertion(message), sleepPreventing.contains(type),
                   process != "powerd" {
                    var entry = preventers[process] ?? Preventer(process: process, count: 0, longestSeconds: 0)
                    entry.count += 1
                    entry.longestSeconds = max(entry.longestSeconds, seconds)
                    preventers[process] = entry
                }
            case "BatteryHealth":
                if message.contains("Warning level") { analysis.lowBatteryWarnings += 1 }
            default:
                break
            }
        }
        analysis.slowDrivers = drivers.values.sorted { ($0.count, $0.maxMilliseconds) > ($1.count, $1.maxMilliseconds) }
            .prefix(5).map { $0 }
        analysis.preventers = preventers.values.sorted { $0.longestSeconds > $1.longestSeconds }.prefix(5).map { $0 }
        return analysis
    }

    /// `pmset -g`: "name value" lines and "sleep 1 (sleep prevented by powerd, Claude)".
    static func parseSettings(_ text: String) -> (settings: [String: String], preventing: [String]) {
        var settings: [String: String] = [:]
        var preventing: [String] = []
        for line in text.split(separator: "\n") where line.hasPrefix(" ") {
            var body = line.trimmingCharacters(in: .whitespaces)
            if let open = body.range(of: "(sleep prevented by ") {
                let list = body[open.upperBound...].prefix { $0 != ")" }
                preventing = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                body = String(body[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            let parts = body.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            settings[parts.dropLast().joined(separator: " ")] = String(parts.last!)
        }
        return (settings, preventing)
    }

    static func quoted(_ s: String) -> String? {
        guard let start = s.firstIndex(of: "'") else { return nil }
        let after = s.index(after: start)
        guard let end = s[after...].firstIndex(of: "'") else { return nil }
        return String(s[after..<end])
    }

    static func onBattery(_ s: String) -> Bool? {
        if s.range(of: "Using Batt", options: .caseInsensitive) != nil { return true }
        if s.contains("Using AC") { return false }
        return nil
    }

    static func charge(_ s: String) -> Int? {
        guard let range = s.range(of: "Charge:") else { return nil }
        return Int(s[range.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    /// "… 14403 secs" at the end of the line.
    static func trailingSeconds(_ s: String) -> Int? {
        let parts = s.split(separator: " ")
        guard parts.count >= 2, parts.last == "secs" else { return nil }
        return Int(parts[parts.count - 2])
    }

    /// "Wake from Hibernate [CDNVA] : due to acattach/UserActivity Assertion Using AC (Charge:4%)"
    /// → "acattach/UserActivity Assertion".
    static func wakeReason(_ s: String) -> String {
        guard let range = s.range(of: "due to ") else { return "" }
        var reason = s[range.upperBound...]
        if let using = reason.range(of: " Using ") { reason = reason[..<using.lowerBound] }
        return reason.trimmingCharacters(in: .whitespaces)
    }

    /// "[AppleANS3NVMeController driver is slow(msg: SetState to 0)(1174 ms)]" → (name, 1174).
    static func slowDrivers(_ s: String) -> [(String, Int)] {
        s.components(separatedBy: "[").dropFirst().compactMap { item in
            guard let slow = item.range(of: " driver is slow") ?? item.range(of: " is slow") else { return nil }
            let name = String(item[..<slow.lowerBound])
            guard let msRange = item.range(of: " ms)", options: .backwards),
                  let open = item[..<msRange.lowerBound].lastIndex(of: "("),
                  let ms = Int(item[item.index(after: open)..<msRange.lowerBound]) else { return nil }
            return (name, ms)
        }
    }

    /// "PID 29772(Claude) Released NoIdleSleepAssertion "Electron" 00:06:44  id:…" → (Claude, type, seconds).
    static func releasedAssertion(_ s: String) -> (String, String, Int)? {
        let parts = s.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, parts[0] == "PID", parts[2] == "Released",
              let open = parts[1].firstIndex(of: "("), parts[1].hasSuffix(")") else { return nil }
        let process = String(parts[1][parts[1].index(after: open)..<parts[1].index(before: parts[1].endIndex)])
        let type = String(parts[3])
        guard let duration = parts.first(where: { $0.split(separator: ":").count == 3 && $0.allSatisfy { $0.isNumber || $0 == ":" } })
        else { return (process, type, 0) }
        let hms = duration.split(separator: ":").compactMap { Int($0) }
        return (process, type, hms[0] * 3600 + hms[1] * 60 + hms[2])
    }
}
