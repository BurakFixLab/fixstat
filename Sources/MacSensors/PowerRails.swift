import Foundation

/// One power rail as the SMC reports it: keys `V…` (volts), `I…` (amps) and `P…` (watts) that
/// share their last three characters, e.g. `VP7l` / `IP7l` / `PP7l`. On Apple Silicon these are
/// the PMU's buck (`…b`) and LDO (`…l`) outputs (`R` in the middle: the second PMU).
public struct PowerRail: Codable, Sendable, Equatable {
    /// The shared key suffix ("P7l").
    public var name: String
    public var volts: Double?
    public var amps: Double?
    public var watts: Double?

    public init(name: String, volts: Double? = nil, amps: Double? = nil, watts: Double? = nil) {
        self.name = name
        self.volts = volts
        self.amps = amps
        self.watts = watts
    }
}

/// Reads the board's power rails from the SMC. Read-only, no root.
public enum PowerRails {
    public struct Keys: Sendable, Equatable {
        public var name: String
        public var volts: String?
        public var amps: String?
        public var watts: String?
    }

    /// Totals that have no V / I partner but matter on their own.
    public static let totals = ["PSTR", "PDTR", "PPBR"]

    /// Groups the SMC's keys into rails: a suffix counts when at least two of its V / I / P
    /// keys exist and are numeric.
    public static func discover(smc: SMC) -> [Keys] {
        guard let all = try? smc.allKeys() else { return [] }
        var groups: [String: Keys] = [:]
        for key in all.map(\.description) where key.count == 4 {
            let first = key.first!
            guard first == "V" || first == "I" || first == "P" else { continue }
            let suffix = String(key.dropFirst())
            guard let value = try? smc.read(key), value.doubleValue != nil else { continue }
            var group = groups[suffix] ?? Keys(name: suffix)
            switch first {
            case "V": group.volts = key
            case "I": group.amps = key
            default: group.watts = key
            }
            groups[suffix] = group
        }
        return groups.values
            .filter { [$0.volts, $0.amps, $0.watts].compactMap { $0 }.count >= 2 }
            .sorted { $0.name < $1.name }
    }

    public static func read(smc: SMC, keys: [Keys]) -> [PowerRail] {
        func value(_ key: String?) -> Double? {
            guard let key, let v = try? smc.read(key).doubleValue, v.isFinite, abs(v) < 1000 else { return nil }
            return v
        }
        return keys.map { PowerRail(name: $0.name, volts: value($0.volts), amps: value($0.amps), watts: value($0.watts)) }
    }

    /// `PSTR` (system total), `PDTR` (DC in), `PPBR` (battery rail) where present, in W.
    public static func readTotals(smc: SMC) -> [String: Double] {
        var out: [String: Double] = [:]
        for key in totals {
            if let v = try? smc.read(key).doubleValue, v.isFinite, abs(v) < 1000 { out[key] = v }
        }
        return out
    }
}
