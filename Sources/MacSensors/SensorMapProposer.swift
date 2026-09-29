import Foundation

/// Builds a proposed model entry for `sensor-map.json` from recordings.
///
/// Names come from the pattern rules of the existing map (the same rules the
/// app uses as last-resort fallback). Test results decide the confidence:
/// a sensor is `verified` only if its strongest rise happened in the test that
/// matches its group (cpu → CPU tests, gpu → GPU, ssd → SSD, battery → charging).
/// Everything else is `estimated`, for the owner to confirm or correct.
public enum SensorMapProposer {
    static let expectedTests: [SensorMap.Group: Set<String>] = [
        .cpu: ["single", "all"],
        .gpu: ["gpu"],
        .ssd: ["ssd"],
        .battery: ["charging"],
    ]

    /// Id prefixes verified by a specific test regardless of their group.
    static let expectedTestsByID: [String: Set<String>] = [
        "board.charger": ["charging"],
        "board.psu": ["charging"],
    ]

    /// Apple Silicon SMC keys like `Tp2a`, `Tc8z`: aggregates of the HID zone sensors.
    static let derivedKeyPattern = "T[a-z][0-9a-z][abxz]"

    /// Minimum rise in °C that counts as a response to a test.
    static let responseThreshold = 1.5
    /// The expected test must reach this share of the strongest rise.
    static let dominance = 0.9

    public struct Proposal: Sendable {
        public var model: SensorMap.ModelMap
        /// Sensors neither the patterns nor the tests could identify.
        public var unmatched: [SensorDescriptor]
    }

    public static func propose(recordings: [SensorRecording], map: SensorMap) -> Proposal {
        let rows = SensorMapReport.deltas(for: recordings)
        let system = recordings[0].system
        let patternsOnly = SensorMap(patterns: map.patterns)

        var entries: [SensorMap.Entry] = []
        var ignored: [String] = []
        var unmatched: [SensorDescriptor] = []
        var derived: [String] = []
        let aliases = findAliases(recordings)

        for row in rows {
            let sensor = row.sensor
            let label = sensor.rawLabel
            let (minimum, maximum) = range(of: sensor, in: recordings)

            guard row.baseline != nil, let minimum, let maximum else {
                ignored.append(label) // never plausible: unpopulated or not a temperature
                continue
            }
            let isConstant = maximum - minimum < 0.05
            guard let resolved = patternsOnly.resolve(key: sensor.key, hidName: sensor.hidName,
                                                      model: system.model, chip: nil) else {
                if sensor.source == .smc, let key = sensor.key,
                   SensorMap.PatternRule.fullMatch(derivedKeyPattern, key) != nil {
                    derived.append(key)
                } else if isConstant {
                    ignored.append(label) // constant and unknown: calibration value or stuck reading
                } else {
                    unmatched.append(sensor)
                }
                continue
            }

            let strongest = row.deltas.values.max() ?? 0
            let byID = expectedTestsByID.first { resolved.id.hasPrefix($0.key) }?.value
            let expected = (byID ?? expectedTests[resolved.group] ?? []).compactMap { row.deltas[$0] }.max() ?? 0
            let confirmed = expected >= responseThreshold && expected >= dominance * strongest
            let confidence: SensorMap.Confidence = confirmed ? .verified : .estimated

            var notes = [sensor.source == .hid ? "HID" : "SMC"]
            if let alias = aliases[sensor.uid] {
                notes.append("same reading as \(alias)")
            }
            if isConstant {
                notes.append("constant during all tests")
            }
            let evidence = SensorMapReport.testOrder.compactMap { test in
                row.deltas[test].map { String(format: "Δ%@ %+.1f", test, $0) }
            }.joined(separator: ", ")
            if !evidence.isEmpty { notes.append(evidence) }
            entries.append(.init(key: label, id: resolved.id, group: resolved.group,
                                 confidence: confidence, hidName: sensor.hidName,
                                 note: notes.joined(separator: "; ")))
        }

        return Proposal(
            model: .init(chip: system.chip, board: system.boardTarget, description: nil,
                         sensors: renumber(entries), ignored: ignored.isEmpty ? nil : ignored,
                         derived: derived.isEmpty ? nil : derived),
            unmatched: unmatched
        )
    }

    /// Maps each SMC sensor uid to the HID sensor that reads the same physical
    /// sensor, and that HID sensor back to the SMC key(s).
    ///
    /// SMC and HID are read a few milliseconds apart and the SMC value is
    /// filtered, so the series are not bit-identical. A pair counts as alias if
    /// the mean absolute difference is below 0.25 °C and the next best HID
    /// candidate is at least twice as far away.
    static func findAliases(_ recordings: [SensorRecording]) -> [String: String] {
        guard let recording = recordings.first else { return [:] }
        let sensors = recording.sensors
        let series: [[Double?]] = sensors.indices.map { index in
            recording.samples.map { index < $0.values.count ? $0.values[index] : nil }
        }
        func meanDifference(_ a: [Double?], _ b: [Double?]) -> Double? {
            var total = 0.0
            var count = 0
            for (x, y) in zip(a, b) {
                guard let x, let y else { continue }
                total += abs(x - y)
                count += 1
            }
            return count > 10 ? total / Double(count) : nil
        }
        var result: [String: [String]] = [:]
        for (i, smc) in sensors.enumerated() where smc.source == .smc {
            let values = series[i].compactMap { $0 }
            // A constant series matches other constants too easily.
            guard let lo = values.min(), let hi = values.max(), hi - lo >= 0.5 else { continue }
            let candidates = sensors.indices
                .filter { sensors[$0].source == .hid }
                .compactMap { j in meanDifference(series[i], series[j]).map { (j, $0) } }
                .sorted { $0.1 < $1.1 }
            guard let best = candidates.first, best.1 < 0.25,
                  candidates.count < 2 || candidates[1].1 >= 2 * best.1 else { continue }
            let hid = sensors[best.0]
            result[smc.uid, default: []].append(hid.rawLabel + (hid.hidName.map { " (\($0))" } ?? ""))
            result[hid.uid, default: []].append(smc.rawLabel)
        }
        return result.mapValues { $0.joined(separator: ", ") }
    }

    /// Plausible min / max of a sensor over all recordings.
    static func range(of sensor: SensorDescriptor, in recordings: [SensorRecording]) -> (Double?, Double?) {
        var values: [Double] = []
        for recording in recordings {
            guard let index = recording.sensors.firstIndex(of: sensor) else { continue }
            for sample in recording.samples where index < sample.values.count {
                if let value = sample.values[index], SMC.plausibleTemperatureRange.contains(value) {
                    values.append(value)
                }
            }
        }
        return (values.min(), values.max())
    }

    /// Renumbers indexed ids per base to 1…n in key order, so that e.g.
    /// cpu.pcluster.{2,3,4,5,7,8,9} become cpu.pcluster.{1…7}. PMU channels keep
    /// their hardware numbers (pmu.ntc.3 = "PMU tdev3").
    static func renumber(_ entries: [SensorMap.Entry]) -> [SensorMap.Entry] {
        func base(_ id: String) -> String {
            let parts = id.split(separator: ".")
            guard let last = parts.last, Int(last) != nil || last.count == 1, parts.count > 2 else { return id }
            return parts.dropLast().joined(separator: ".")
        }
        var counts: [String: Int] = [:]
        for entry in entries { counts[base(entry.id), default: 0] += 1 }
        var next: [String: Int] = [:]
        return entries
            .sorted { ($0.group.rawValue, base($0.id), $0.key) < ($1.group.rawValue, base($1.id), $1.key) }
            .map { entry in
                var entry = entry
                let b = base(entry.id)
                if b.hasPrefix("pmu") { return entry }
                if b != entry.id || (counts[b] ?? 0) > 1 {
                    next[b, default: 0] += 1
                    entry.id = "\(b).\(next[b]!)"
                }
                return entry
            }
    }
}
