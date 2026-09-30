import Foundation
import MacSensors

/// Time ranges of the battery history window (both interfaces).
public enum HistoryRange: Int, CaseIterable {
    case hour1, hours3, hours6, hours12, day, week, month

    public var duration: TimeInterval {
        let hour: TimeInterval = 3_600
        switch self {
        case .hour1: return hour
        case .hours3: return 3 * hour
        case .hours6: return 6 * hour
        case .hours12: return 12 * hour
        case .day: return 24 * hour
        case .week: return 7 * 24 * hour
        case .month: return 30 * 24 * hour
        }
    }

    /// Bucket size so that every range has at most ~360 points. Up to 6 h the
    /// raw minute samples are shown.
    public var bucket: TimeInterval {
        switch self {
        case .hour1, .hours3, .hours6: return 60
        case .hours12: return 120
        case .day: return 240
        case .week: return 1_800
        case .month: return 7_200
        }
    }

    /// "1 hour", "12 hours", "1 day", "7 days" in the user's language.
    public var title: String { Format.durationWide(duration) }

    /// Tick spacing of the time axis.
    public var tick: TimeInterval {
        switch self {
        case .hour1: return 600
        case .hours3: return 1_800
        case .hours6: return 3_600
        case .hours12: return 2 * 3_600
        case .day: return 4 * 3_600
        case .week: return 86_400
        case .month: return 5 * 86_400
        }
    }

    /// Time labels include the date for ranges longer than a day.
    public var showsDate: Bool { duration > 86_400 }
}

/// Values derived from the history for display and export.
public enum HistoryData {
    /// Samples of the range, bucketed.
    public static func samples(_ store: BatteryHistoryStore, range: HistoryRange, now: Date = Date()) -> [BatteryHistorySample] {
        BatteryHistoryStore.bucketed(store.samples(since: now.addingTimeInterval(-range.duration)), interval: range.bucket)
    }

    /// Average charge / discharge current and the highest temperature.
    public static func summary(_ samples: [BatteryHistorySample])
        -> (charge: Double?, discharge: Double?, temperature: Double?) {
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return (mean(samples.filter { $0.amperage > 0 }.map { Double($0.amperage) }),
                mean(samples.filter { $0.amperage < 0 }.map { Double($0.amperage) }),
                samples.compactMap(\.temperature).max())
    }

    /// At least the last 7 days, padded by half a day, so a short health history does
    /// not zoom the axis into hours.
    public static func healthDomain(_ dates: [Date], now: Date = Date()) -> ClosedRange<Date> {
        let start = min(dates.min() ?? now, now.addingTimeInterval(-7 * 86_400)).addingTimeInterval(-43_200)
        let end = max(dates.max() ?? now, now).addingTimeInterval(43_200)
        return start...end
    }

    /// Lower end of the health axis: 5 points below the lowest value, whole number.
    public static func healthFloor(_ values: [Double]) -> Double {
        max(0, ((values.min() ?? 80) - 5).rounded(.down))
    }

    /// "Charging", "On power adapter" or "On battery" for a sample.
    public static func state(_ sample: BatteryHistorySample) -> String {
        sample.isCharging ? L("Charging") : (sample.externalConnected ? L("On power adapter") : L("On battery"))
    }

    // MARK: Export

    private struct Payload: Encodable {
        let app = "FixStat"
        let model: String
        let samples: [BatteryHistorySample]
        let health: [BatteryHealthRecord]
    }

    /// CSV of the samples with ISO 8601 times.
    public static func csv(_ samples: [BatteryHistorySample]) -> Data {
        let iso = ISO8601DateFormatter()
        let header = "time,stateOfCharge,health,amperage,voltage,temperature,isCharging,externalConnected"
        let rows = samples.map { sample -> String in
            var fields = BatteryHistoryStore.csvLine(sample).split(separator: ",", omittingEmptySubsequences: false)
            fields[0] = Substring(iso.string(from: sample.time))
            return fields.joined(separator: ",")
        }
        return Data(([header] + rows).joined(separator: "\n").appending("\n").utf8)
    }

    /// JSON of the samples and the daily health records.
    public static func json(model: String, samples: [BatteryHistorySample], health: [BatteryHealthRecord]) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(Payload(model: model, samples: samples, health: health))
    }

    /// "FixStat-battery-history-MacBookAir10,1-2026-09-30.csv"
    public static func fileName(model: String, csv: Bool, now: Date = Date()) -> String {
        "FixStat-battery-history-\(model)-\(Format.isoDay(now)).\(csv ? "csv" : "json")"
    }
}
