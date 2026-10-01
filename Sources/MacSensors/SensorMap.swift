import Foundation

/// Sensor naming database (`sensor-map.json`).
///
/// Lookup is layered, first match wins:
/// 1. model entry (`hw.model`), `verified` or `estimated`
/// 2. chip entry (`machdep.cpu.brand_string`), always treated as estimated
/// 3. pattern rule on the raw key / HID name, always treated as estimated
///
/// Display names are not stored here: `id` is the localization key. An id has
/// the form `<base>` or `<base>.<n>` (e.g. `cpu.pcluster.2`); the catalog has
/// one entry per base, with the index formatted in.
public struct SensorMap: Codable, Sendable, Equatable {
    public enum Group: String, Codable, Sendable, CaseIterable {
        case cpu, gpu, ssd, battery, chassis, other
    }

    public enum Confidence: String, Codable, Sendable {
        case verified, estimated
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// Raw key: SMC key / HID LocationID FourCC (e.g. "Tp2i"), or the HID
        /// Product name for services without a LocationID.
        public var key: String
        public var id: String
        public var group: Group
        public var confidence: Confidence
        /// HID Product name at the time of mapping (informational).
        public var hidName: String?
        /// Why this mapping was chosen (test results, naming convention).
        public var note: String?
        /// A display name set by the user. Overrides the localized name of `id`.
        /// Only used in the user's own map, not in the bundled one.
        public var name: String?

        public init(key: String, id: String, group: Group, confidence: Confidence,
                    hidName: String? = nil, note: String? = nil, name: String? = nil) {
            self.key = key
            self.id = id
            self.group = group
            self.confidence = confidence
            self.hidName = hidName
            self.note = note
            self.name = name
        }
    }

    public struct ModelMap: Codable, Sendable, Equatable {
        public var chip: String?
        /// Board target / name, e.g. "J313".
        public var board: String?
        public var description: String?
        public var sensors: [Entry]
        /// Raw keys that are known to be meaningless on this model (e.g. unpopulated
        /// thermistor channels, calibration values). Shown only in the raw list.
        public var ignored: [String]?
        /// SMC keys that are derived from / aggregate other sensors (e.g. Apple
        /// Silicon `Tp2a/b/x/z` next to the real `Tp2i`). Shown only in the raw list.
        public var derived: [String]?

        public init(chip: String?, board: String?, description: String?,
                    sensors: [Entry], ignored: [String]?, derived: [String]? = nil) {
            self.chip = chip
            self.board = board
            self.description = description
            self.sensors = sensors
            self.ignored = ignored
            self.derived = derived
        }
    }

    /// Sensors of one chip (e.g. "Apple M2 Pro"), for all models with that chip. On Apple
    /// Silicon after M1 the CPU / GPU die zones exist only as SMC keys, the same on every
    /// model with the chip.
    public struct ChipMap: Codable, Sendable, Equatable {
        public var sensors: [Entry]
        /// Raw keys that are meaningless on this chip (constants, calibration values).
        public var ignored: [String]?
        /// Raw keys derived from other sensors (uncalibrated readings, peaks, averages).
        public var derived: [String]?

        public init(sensors: [Entry], ignored: [String]? = nil, derived: [String]? = nil) {
            self.sensors = sensors
            self.ignored = ignored
            self.derived = derived
        }
    }

    /// Regex-based guess. `id` may reference capture groups as `$1`, `$2`.
    public struct PatternRule: Codable, Sendable, Equatable {
        /// Regular expression matched against the whole raw key.
        public var key: String?
        /// Regular expression matched against the whole HID name.
        public var hidName: String?
        public var id: String
        public var group: Group
        public var note: String?

        public init(key: String?, hidName: String?, id: String, group: Group, note: String?) {
            self.key = key
            self.hidName = hidName
            self.id = id
            self.group = group
            self.note = note
        }
    }

    public var schemaVersion: Int
    public var models: [String: ModelMap]
    public var chips: [String: ChipMap]
    public var patterns: [PatternRule]

    public init(schemaVersion: Int = 1, models: [String: ModelMap] = [:],
                chips: [String: ChipMap] = [:], patterns: [PatternRule] = []) {
        self.schemaVersion = schemaVersion
        self.models = models
        self.chips = chips
        self.patterns = patterns
    }

    public static func load(from url: URL) throws -> SensorMap {
        try JSONDecoder().decode(SensorMap.self, from: Data(contentsOf: url))
    }
}

/// Result of resolving one sensor.
public struct ResolvedSensor: Sendable, Equatable {
    public enum Level: String, Sendable {
        case model, chip, pattern
    }

    public let id: String
    public let group: SensorMap.Group
    public let confidence: SensorMap.Confidence
    public let level: Level
    /// User-defined display name, if any.
    public var name: String?

    public init(id: String, group: SensorMap.Group, confidence: SensorMap.Confidence,
                level: Level, name: String? = nil) {
        self.id = id
        self.group = group
        self.confidence = confidence
        self.level = level
        self.name = name
    }
}

public extension SensorMap {
    /// Resolves a sensor. Chip and pattern matches are always `estimated`;
    /// a model entry always wins over chip and pattern entries.
    func resolve(key: String?, hidName: String?, model: String, chip: String?) -> ResolvedSensor? {
        let lookup = [key, hidName].compactMap { $0 }
        guard !lookup.isEmpty else { return nil }

        if let entry = models[model]?.sensors.first(where: { lookup.contains($0.key) }) {
            return ResolvedSensor(id: entry.id, group: entry.group, confidence: entry.confidence,
                                  level: .model, name: entry.name)
        }
        if let chip, let entry = chips[chip]?.sensors.first(where: { lookup.contains($0.key) }) {
            return ResolvedSensor(id: entry.id, group: entry.group, confidence: .estimated, level: .chip)
        }
        for rule in patterns {
            if let id = rule.match(key: key, hidName: hidName) {
                return ResolvedSensor(id: id, group: rule.group, confidence: .estimated, level: .pattern)
            }
        }
        return nil
    }

    /// This map with `overrides` layered on top: model entries of the override
    /// replace entries with the same key; its ignored/derived lists are added.
    func merged(with overrides: SensorMap) -> SensorMap {
        var result = self
        for (model, override) in overrides.models {
            guard var base = result.models[model] else {
                result.models[model] = override
                continue
            }
            let replaced = Set(override.sensors.map(\.key))
            base.sensors = override.sensors + base.sensors.filter { !replaced.contains($0.key) }
            if let ignored = override.ignored { base.ignored = (base.ignored ?? []) + ignored }
            if let derived = override.derived { base.derived = (base.derived ?? []) + derived }
            result.models[model] = base
        }
        for (chip, override) in overrides.chips {
            let replaced = Set(override.sensors.map(\.key))
            let base = result.chips[chip]
            let existing = base?.sensors.filter { !replaced.contains($0.key) } ?? []
            func joined(_ a: [String]?, _ b: [String]?) -> [String]? {
                a == nil && b == nil ? nil : (a ?? []) + (b ?? [])
            }
            result.chips[chip] = ChipMap(sensors: override.sensors + existing,
                                         ignored: joined(base?.ignored, override.ignored),
                                         derived: joined(base?.derived, override.derived))
        }
        result.patterns = overrides.patterns + result.patterns
        return result
    }

    /// Whether the model (or, without a model entry naming the sensor, the chip) lists the
    /// key as meaningless or derived, i.e. it should only appear in the raw list.
    func isIgnored(key: String?, hidName: String?, model: String, chip: String? = nil) -> Bool {
        let lookup = [key, hidName].compactMap { $0 }
        if let entry = models[model] {
            if lookup.contains(where: ((entry.ignored ?? []) + (entry.derived ?? [])).contains) { return true }
            // A sensor the model names is shown even if the chip lists it.
            if entry.sensors.contains(where: { lookup.contains($0.key) }) { return false }
        }
        guard let chip, let entry = chips[chip] else { return false }
        return lookup.contains(where: ((entry.ignored ?? []) + (entry.derived ?? [])).contains)
    }
}

public extension SensorMap.PatternRule {
    /// Returns the expanded id if the rule matches.
    internal func match(key: String?, hidName: String?) -> String? {
        // Every given condition must match; a rule without conditions never matches.
        var groups: [String] = []
        var conditions = 0
        for (pattern, value) in [(self.key, key), (self.hidName, hidName)] {
            guard let pattern else { continue }
            conditions += 1
            guard let value, let captured = Self.fullMatch(pattern, value) else { return nil }
            groups += captured
        }
        guard conditions > 0 else { return nil }
        var id = self.id
        for (index, group) in groups.enumerated().reversed() {
            id = id.replacingOccurrences(of: "$\(index + 1)", with: group)
        }
        return id
    }

    /// Capture groups of a whole-string match, or nil.
    static func fullMatch(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return nil }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
        }
    }
}
