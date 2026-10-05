import Foundation

/// Finds the CPU / GPU die zones of Apple Silicon after M1 in a recording and proposes a
/// chip entry for `sensor-map.json`.
///
/// These chips have no die sensors in HID; the zones are SMC keys `Tp..` (performance
/// clusters), `Te..` (efficiency cluster) and `Tg..` (GPU). CPU keys come in triplets: a
/// raw reading, the calibrated reading (raw + a constant offset, the one to show) and a
/// noisier peak; GPU keys in pairs (raw, calibrated). The triplets are not aligned to the
/// key alphabet on every chip (M4), so they are found from the data: neighbours (in key
/// order) whose difference stays constant (within `Family.tolerance`). Exact copies of
/// other keys (cluster maxima) are derived; constant keys are calibration values and
/// ignored. What fits no rule is listed for review (e.g. the cluster averages `Tp3*` on M4).
public enum ChipZoneAnalyzer {
    public struct Result: Codable, Sendable, Equatable {
        public var chip: String
        public var entry: SensorMap.ChipMap
        /// Keys of the zone families that fit no rule, to be checked by hand.
        public var review: [String]
    }

    struct Family {
        let prefix: String
        let id: String
        let group: SensorMap.Group
        let what: String
        /// Allowed standard deviation of the raw → calibrated difference (°C). GPU pairs
        /// wander more (M3: ≈ 0.6) than CPU triplets; a looser CPU limit would take the
        /// cluster averages of M4 (`Tp3*`, `Te0U–X`) for zones.
        var tolerance = 0.25
    }

    static let families = [
        Family(prefix: "Tp", id: "cpu.pcluster", group: .cpu, what: "performance cluster"),
        Family(prefix: "Te", id: "cpu.ecluster", group: .cpu, what: "efficiency cluster"),
        Family(prefix: "Tg", id: "gpu.cluster", group: .gpu, what: "GPU", tolerance: 0.7),
    ]
    /// Further SoC keys of these chips: only their constants are classified (ignored).
    static let otherPrefixes = ["Tf"]

    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// Sort position of a key within its family ("Tp1A" after "Tp0z").
    static func order(_ key: String) -> Int {
        let chars = Array(key)
        guard chars.count == 4, let a = alphabet.firstIndex(of: chars[2]), let b = alphabet.firstIndex(of: chars[3])
        else { return Int.max }
        return a * alphabet.count + b
    }

    /// nil for Intel, and for M1-type chips whose die zones are HID services.
    public static func analyze(_ recording: SensorRecording) -> Result? {
        guard recording.system.isAppleSilicon,
              !recording.sensors.contains(where: { $0.hidName?.contains("MTR Temp Sensor") == true }) else { return nil }
        var series: [String: [Double?]] = [:]
        for (index, sensor) in recording.sensors.enumerated() where sensor.source == .smc {
            guard let key = sensor.key else { continue }
            series[key] = recording.samples.map { index < $0.values.count ? $0.values[index] : nil }
        }
        let model = recording.system.model

        func pairs(_ a: String, _ b: String) -> [Double] {
            guard let x = series[a], let y = series[b] else { return [] }
            return zip(x, y).compactMap { p, q in
                guard let p, let q, (-20.0...130).contains(p), (-20.0...130).contains(q) else { return nil }
                return q - p
            }
        }
        func constantOffset(_ a: String, _ b: String, tolerance: Double) -> Bool {
            let d = pairs(a, b)
            guard d.count > 20 else { return false }
            let mean = d.reduce(0, +) / Double(d.count)
            let deviation = (d.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(d.count)).squareRoot()
            return deviation < tolerance && (0.3..<15).contains(mean)
        }
        func sameAs(_ a: String, _ b: String) -> Bool {
            let d = pairs(a, b)
            return d.count > 20 && d.map(abs).reduce(0, +) / Double(d.count) < 0.05
        }
        func range(_ key: String) -> (Double, Double)? {
            let values = (series[key] ?? []).compactMap { $0 }
            guard let lo = values.min(), let hi = values.max() else { return nil }
            return (lo, hi)
        }
        func isConstant(_ key: String) -> Bool {
            guard let (lo, hi) = range(key) else { return true }
            return hi - lo < 0.05
        }

        var sensors: [SensorMap.Entry] = []
        var derived: [String] = []
        var ignored: [String] = []
        var review: [String] = []

        for prefix in otherPrefixes {
            for key in series.keys.filter({ $0.hasPrefix(prefix) }).sorted(by: { order($0) < order($1) }) {
                guard let (lo, hi) = range(key) else { continue }
                if hi - lo < 0.5 || hi < SMC.plausibleTemperatureRange.lowerBound { ignored.append(key) }
            }
        }

        for family in families {
            let keys = series.keys.filter { $0.hasPrefix(family.prefix) }.sorted { order($0) < order($1) }
            var used = Set<String>()
            var zone = 0
            for (i, key) in keys.enumerated() where !used.contains(key) {
                if isConstant(key) {
                    ignored.append(key)
                    used.insert(key)
                    continue
                }
                if i + 1 < keys.count, constantOffset(key, keys[i + 1], tolerance: family.tolerance) {
                    let calibrated = keys[i + 1]
                    used.formUnion([key, calibrated])
                    derived.append(key)
                    // A third key of the same block that does not start the next pair: the peak.
                    if i + 2 < keys.count {
                        let next = keys[i + 2]
                        let startsPair = i + 3 < keys.count && constantOffset(next, keys[i + 3], tolerance: family.tolerance)
                        if !startsPair, !isConstant(next), next.prefix(3) == calibrated.prefix(3) {
                            used.insert(next)
                            derived.append(next)
                        }
                    }
                    zone += 1
                    sensors.append(.init(
                        key: calibrated, id: "\(family.id).\(zone)", group: family.group, confidence: .estimated,
                        note: "SMC, \(family.what) thermal zone: calibrated reading (raw key + constant offset); "
                            + "reads 0 + offset while power gated; from a \(model) recording"))
                } else if keys.contains(where: { $0 != key && sameAs(key, $0) }) {
                    derived.append(key)
                    used.insert(key)
                } else {
                    review.append(key)
                }
            }
        }
        guard !sensors.isEmpty else { return nil }
        return Result(chip: recording.system.chip,
                      entry: SensorMap.ChipMap(sensors: sensors,
                                               ignored: ignored.isEmpty ? nil : ignored,
                                               derived: derived.isEmpty ? nil : derived),
                      review: review)
    }
}
