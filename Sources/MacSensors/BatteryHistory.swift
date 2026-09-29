import Foundation

/// One battery sample, recorded about once a minute.
public struct BatteryHistorySample: Codable, Sendable, Equatable {
    public var time: Date
    /// State of charge in %.
    public var stateOfCharge: Double
    /// AppleRawMaxCapacity / DesignCapacity in %.
    public var health: Double?
    /// mA, positive = charging.
    public var amperage: Int
    /// mV
    public var voltage: Int
    /// °C
    public var temperature: Double?
    public var isCharging: Bool
    public var externalConnected: Bool

    public init(time: Date, stateOfCharge: Double, health: Double?, amperage: Int, voltage: Int,
                temperature: Double?, isCharging: Bool, externalConnected: Bool) {
        self.time = time
        self.stateOfCharge = stateOfCharge
        self.health = health
        self.amperage = amperage
        self.voltage = voltage
        self.temperature = temperature
        self.isCharging = isCharging
        self.externalConnected = externalConnected
    }

    public init?(_ battery: BatteryInfo, at time: Date) {
        guard let soc = battery.stateOfCharge, let amperage = battery.amperage, let voltage = battery.voltage else {
            return nil
        }
        self.init(time: time, stateOfCharge: soc, health: battery.healthPercent, amperage: amperage,
                  voltage: voltage, temperature: battery.temperature,
                  isCharging: battery.isCharging == true, externalConnected: battery.externalConnected == true)
    }
}

/// Battery health for one day. Kept forever (one line per day).
public struct BatteryHealthRecord: Codable, Sendable, Equatable {
    /// Local calendar day, "yyyy-MM-dd".
    public var day: String
    public var health: Double
    public var nominalHealth: Double?
    public var cycleCount: Int?
    public var rawMaxCapacity: Int?
    public var designCapacity: Int?

    /// Noon of `day` in the current time zone (for charting).
    public var date: Date? {
        BatteryHistoryStore.dayFormatter.date(from: day).map { $0.addingTimeInterval(12 * 3600) }
    }
}

/// Append-only CSV storage for battery history.
///
/// - `battery-samples.csv`: minute samples, pruned to `retention` (default 30 days).
/// - `battery-health.csv`: one line per day, never pruned.
///
/// Plain CSV keeps appends cheap (no rewrite) and the files readable by hand.
public final class BatteryHistoryStore {
    public let directory: URL
    public let retention: TimeInterval
    public var samplesURL: URL { directory.appendingPathComponent("battery-samples.csv") }
    public var healthURL: URL { directory.appendingPathComponent("battery-health.csv") }

    static let sampleHeader = "time,stateOfCharge,health,amperage,voltage,temperature,isCharging,externalConnected"
    static let healthHeader = "day,health,nominalHealth,cycleCount,rawMaxCapacity,designCapacity"

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var lastHealthDay: String?

    public init(directory: URL, retention: TimeInterval = 30 * 24 * 3600) {
        self.directory = directory
        self.retention = retention
        lastHealthDay = healthRecords().last?.day
    }

    // MARK: Writing

    /// Appends a sample and, once per day, a health record.
    public func record(_ battery: BatteryInfo, at time: Date = Date()) {
        if let sample = BatteryHistorySample(battery, at: time) {
            append(line: Self.csvLine(sample), header: Self.sampleHeader, to: samplesURL)
        }
        let day = Self.dayFormatter.string(from: time)
        if day != lastHealthDay, let health = battery.healthPercent {
            let record = BatteryHealthRecord(day: day, health: health, nominalHealth: battery.nominalHealthPercent,
                                             cycleCount: battery.cycleCount, rawMaxCapacity: battery.rawMaxCapacity,
                                             designCapacity: battery.designCapacity)
            append(line: Self.csvLine(record), header: Self.healthHeader, to: healthURL)
            lastHealthDay = day
        }
    }

    /// Drops samples older than the retention period (rewrites the file).
    public func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-retention)
        let all = samples()
        let kept = all.filter { $0.time >= cutoff }
        guard kept.count != all.count else { return }
        let text = ([Self.sampleHeader] + kept.map(Self.csvLine)).joined(separator: "\n") + "\n"
        try? Data(text.utf8).write(to: samplesURL, options: .atomic)
    }

    private func append(line: String, header: String, to url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data((header + "\n").utf8).write(to: url)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        // The pre-10.15 methods: the throwing ones need macOS 10.15.4 (the library also
        // builds for macOS 10.13).
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
    }

    // MARK: Reading

    public func samples(since start: Date = .distantPast) -> [BatteryHistorySample] {
        lines(of: samplesURL).compactMap(Self.parseSample).filter { $0.time >= start }
    }

    public func healthRecords() -> [BatteryHealthRecord] {
        lines(of: healthURL).compactMap(Self.parseHealth)
    }

    private func lines(of url: URL) -> [Substring] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst().map { $0 }
    }

    // MARK: CSV

    static func number(_ value: Double?, digits: Int = 2) -> String {
        guard let value else { return "" }
        return String(format: "%.\(digits)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func csvLine(_ s: BatteryHistorySample) -> String {
        [String(Int(s.time.timeIntervalSince1970)), number(s.stateOfCharge, digits: 1), number(s.health),
         String(s.amperage), String(s.voltage), number(s.temperature), s.isCharging ? "1" : "0",
         s.externalConnected ? "1" : "0"].joined(separator: ",")
    }

    public static func csvLine(_ r: BatteryHealthRecord) -> String {
        [r.day, number(r.health), number(r.nominalHealth), r.cycleCount.map(String.init) ?? "",
         r.rawMaxCapacity.map(String.init) ?? "", r.designCapacity.map(String.init) ?? ""].joined(separator: ",")
    }

    static func parseSample(_ line: Substring) -> BatteryHistorySample? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 8, let epoch = Double(f[0]), let soc = Double(f[1]),
              let amperage = Int(f[3]), let voltage = Int(f[4]) else { return nil }
        return BatteryHistorySample(time: Date(timeIntervalSince1970: epoch), stateOfCharge: soc,
                                    health: Double(f[2]), amperage: amperage, voltage: voltage,
                                    temperature: Double(f[5]), isCharging: f[6] == "1", externalConnected: f[7] == "1")
    }

    static func parseHealth(_ line: Substring) -> BatteryHealthRecord? {
        let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 6, let health = Double(f[1]) else { return nil }
        return BatteryHealthRecord(day: f[0], health: health, nominalHealth: Double(f[2]),
                                   cycleCount: Int(f[3]), rawMaxCapacity: Int(f[4]), designCapacity: Int(f[5]))
    }

    // MARK: Aggregation

    /// Averages samples into buckets of `interval` seconds so charts stay light.
    /// A bucket counts as charging / external if most of its samples do.
    public static func bucketed(_ samples: [BatteryHistorySample], interval: TimeInterval) -> [BatteryHistorySample] {
        guard interval > 0 else { return samples }
        var buckets: [Int: [BatteryHistorySample]] = [:]
        for sample in samples {
            buckets[Int(sample.time.timeIntervalSince1970 / interval), default: []].append(sample)
        }
        return buckets.keys.sorted().compactMap { key in
            guard let group = buckets[key], !group.isEmpty else { return nil }
            let n = Double(group.count)
            func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
            return BatteryHistorySample(
                time: Date(timeIntervalSince1970: (Double(key) + 0.5) * interval),
                stateOfCharge: group.map(\.stateOfCharge).reduce(0, +) / n,
                health: mean(group.compactMap(\.health)),
                amperage: Int((Double(group.map(\.amperage).reduce(0, +)) / n).rounded()),
                voltage: Int((Double(group.map(\.voltage).reduce(0, +)) / n).rounded()),
                temperature: mean(group.compactMap(\.temperature)),
                isCharging: Double(group.filter(\.isCharging).count) > n / 2,
                externalConnected: Double(group.filter(\.externalConnected).count) > n / 2
            )
        }
    }
}
