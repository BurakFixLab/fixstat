import Foundation

/// Per-sensor temperature change for each test.
public struct SensorDeltas: Sendable {
    public let sensor: SensorDescriptor
    /// Mean during the baseline phase (first recording that has one).
    public var baseline: Double?
    /// Test name → Δ °C (mean of the last 10 s of the test minus mean of the
    /// last 10 s before it).
    public var deltas: [String: Double] = [:]
}

public enum SensorMapReport {
    public static let testOrder = ["single", "all", "gpu", "ssd", "charging"]

    static func fmt(_ value: Double?, _ digits: Int = 1) -> String {
        guard let value else { return "-" }
        return String(format: "%.\(digits)f", value)
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Mean of sensor `index` over samples with `from <= t <= to`.
    static func mean(_ recording: SensorRecording, index: Int, from: Double, to: Double) -> Double? {
        mean(recording.samples.filter { $0.t >= from && $0.t <= to }.compactMap { sample in
            guard index < sample.values.count, let value = sample.values[index],
                  SMC.plausibleTemperatureRange.contains(value) else { return nil }
            return value
        })
    }

    /// Computes deltas for all sensors of all recordings. Sensors are matched
    /// across recordings by uid.
    public static func deltas(for recordings: [SensorRecording]) -> [SensorDeltas] {
        var order: [String] = []
        var result: [String: SensorDeltas] = [:]
        for recording in recordings {
            for (index, sensor) in recording.sensors.enumerated() {
                if result[sensor.uid] == nil {
                    order.append(sensor.uid)
                    result[sensor.uid] = SensorDeltas(sensor: sensor)
                }
                if result[sensor.uid]?.baseline == nil,
                   let base = recording.phases.first(where: { $0.name == "baseline" }) {
                    result[sensor.uid]?.baseline = mean(recording, index: index, from: base.start, to: base.end)
                }
                for (phaseIndex, phase) in recording.phases.enumerated() where testOrder.contains(phase.name) {
                    // Reference: the last 10 s of the preceding phase.
                    let reference = phaseIndex > 0 ? recording.phases[phaseIndex - 1] : phase
                    let before = mean(recording, index: index, from: max(reference.start, reference.end - 10), to: reference.end)
                    let after = mean(recording, index: index, from: max(phase.start, phase.end - 10), to: phase.end)
                    if let before, let after {
                        result[sensor.uid]?.deltas[phase.name] = after - before
                    }
                }
            }
        }
        return order.compactMap { result[$0] }
    }

    public static func render(_ rows: [SensorDeltas], tests: [String]) -> String {
        var lines: [String] = []
        let header = ["Key", "HID name", "Base"] + tests.map { "Δ" + $0 } + ["Strongest"]
        var table: [[String]] = [header]
        for row in rows {
            let strongest = tests.compactMap { test in row.deltas[test].map { (test, $0) } }
                .max { $0.1 < $1.1 }
            let label = strongest.flatMap { $0.1 >= 1.0 ? $0.0 : nil } ?? "-"
            table.append([row.sensor.rawLabel, row.sensor.hidName ?? "", fmt(row.baseline)]
                         + tests.map { fmt(row.deltas[$0]) } + [label])
        }
        let widths = header.indices.map { column in table.map { $0[column].count }.max() ?? 0 }
        for (i, cells) in table.enumerated() {
            let line = cells.enumerated().map { column, cell in
                let pad = String(repeating: " ", count: widths[column] - cell.count)
                return column <= 1 ? cell + pad : pad + cell
            }.joined(separator: "  ")
            lines.append(line)
            if i == 0 { lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")) }
        }
        return lines.joined(separator: "\n")
    }
}
