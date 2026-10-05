import Darwin
import Foundation

/// Battery drain while the Mac was shut down.
///
/// Two sources:
/// - **log**: the last battery charge in the power log (`pmset -g log`, "Charge: N")
///   before a shutdown and the first after the next boot, with shutdown / boot times from
///   the login records (wtmp). Whole percent only, so short periods are rough.
/// - **measured**: FixStat stores the gauge's remaining capacity (mAh) when macOS
///   announces a power off and compares it at the next launch. mAh per hour is the
///   average current drawn while off.
///
/// A Mac that is shut down should lose very little; a high rate points to a leakage
/// current on the board (or a battery with high self-discharge).
public struct OffPeriod: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable { case log, measured }

    public var source: Source
    public var shutdown: Date
    public var boot: Date
    /// Displayed charge in % before / after.
    public var chargeBefore: Double?
    public var chargeAfter: Double?
    /// Gauge remaining capacity in mAh before / after (measured only).
    public var remainingBefore: Int?
    public var remainingAfter: Int?
    /// Gauge full charge capacity, for converting % to mAh.
    public var fullChargeCapacity: Int?
    /// The shutdown time is the last log entry (no shutdown record, e.g. the battery died).
    public var shutdownEstimated: Bool

    public init(source: Source, shutdown: Date, boot: Date, chargeBefore: Double?, chargeAfter: Double?,
                remainingBefore: Int? = nil, remainingAfter: Int? = nil, fullChargeCapacity: Int? = nil,
                shutdownEstimated: Bool = false) {
        self.source = source
        self.shutdown = shutdown
        self.boot = boot
        self.chargeBefore = chargeBefore
        self.chargeAfter = chargeAfter
        self.remainingBefore = remainingBefore
        self.remainingAfter = remainingAfter
        self.fullChargeCapacity = fullChargeCapacity
        self.shutdownEstimated = shutdownEstimated
    }

    public var hours: Double { boot.timeIntervalSince(shutdown) / 3600 }

    /// Charge lost in mAh (measured) or estimated from the percentages and the capacity.
    public var lostMAh: Double? {
        if let a = remainingBefore, let b = remainingAfter { return Double(a - b) }
        if let a = chargeBefore, let b = chargeAfter, let fcc = fullChargeCapacity { return (a - b) / 100 * Double(fcc) }
        return nil
    }

    public var lostPercent: Double? {
        if let a = chargeBefore, let b = chargeAfter { return a - b }
        if let mAh = lostMAh, let fcc = fullChargeCapacity, fcc > 0 { return mAh / Double(fcc) * 100 }
        return nil
    }

    /// Average current while off, mA (= mAh per hour).
    /// Mean drain in mA; nil when the battery was charged meanwhile (adapter connected).
    public var averageCurrent: Double? {
        guard hours > 0, let mAh = lostMAh, mAh >= 0 else { return nil }
        return mAh / hours
    }

    /// Usable for a rate: long enough and the battery was not charged meanwhile.
    public var isUsable: Bool {
        guard hours >= 2, let lost = lostPercent ?? lostMAh else { return false }
        return lost >= 0
    }
}

public enum OffStateDrain {
    /// Summary over usable periods: % per hour and mA.
    public static func summary(_ periods: [OffPeriod]) -> (percentPerHour: Double?, milliamps: Double?, hours: Double)? {
        let usable = periods.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }
        let hours = usable.map(\.hours).reduce(0, +)
        let percent = usable.compactMap(\.lostPercent)
        let mAh = usable.compactMap(\.lostMAh)
        return (percent.count == usable.count ? percent.reduce(0, +) / hours : nil,
                mAh.count == usable.count ? mAh.reduce(0, +) / hours : nil, hours)
    }

    /// Boot and shutdown records from wtmp (what `last reboot shutdown` shows), oldest first.
    public static func bootRecords() -> [(date: Date, isBoot: Bool)] {
        var records: [(Date, Bool)] = []
        setutxent_wtmp(0)
        while let entry = getutxent_wtmp() {
            let type = Int32(entry.pointee.ut_type)
            guard type == BOOT_TIME || type == SHUTDOWN_TIME else { continue }
            let tv = entry.pointee.ut_tv
            records.append((Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6),
                            type == BOOT_TIME))
        }
        endutxent_wtmp()
        return records.sorted { $0.0 < $1.0 }
    }

    /// Off periods from the power log and the boot records.
    public static func fromLog(_ log: String, records: [(date: Date, isBoot: Bool)],
                               fullChargeCapacity: Int?) -> [OffPeriod] {
        // (date, charge) of every line that mentions the charge.
        var charges: [(Date, Double)] = []
        var lastLineDates: [Date] = []
        for raw in log.split(separator: "\n") {
            guard raw.count > 26, let date = SleepAnalysis.dateFormatter.date(from: String(raw.prefix(25))) else { continue }
            lastLineDates.append(date)
            if let c = SleepAnalysis.charge(String(raw)) ?? summaryCharge(String(raw)) { charges.append((date, Double(c))) }
        }
        guard let logStart = lastLineDates.first else { return [] }
        var periods: [OffPeriod] = []
        for (index, record) in records.enumerated() where record.isBoot && record.date > logStart {
            let previous = index > 0 ? records[index - 1] : nil
            var shutdown: Date
            var estimated = false
            if let previous, !previous.isBoot {
                shutdown = previous.date
            } else {
                // No shutdown record: the Mac lost power. Use the last log entry before the boot.
                guard let last = lastLineDates.last(where: { $0 < record.date }) else { continue }
                shutdown = last
                estimated = true
            }
            guard shutdown > logStart,
                  let before = charges.last(where: { $0.0 <= shutdown && shutdown.timeIntervalSince($0.0) < 3600 }),
                  let after = charges.first(where: { $0.0 >= record.date && $0.0.timeIntervalSince(record.date) < 900 })
            else { continue }
            if estimated { shutdown = before.0 }
            periods.append(OffPeriod(source: .log, shutdown: shutdown, boot: record.date, chargeBefore: before.1,
                                     chargeAfter: after.1, fullChargeCapacity: fullChargeCapacity,
                                     shutdownEstimated: estimated))
        }
        return periods
    }

    /// "Summary- [System: …] Using Batt(Charge: 17)"
    static func summaryCharge(_ line: String) -> Int? {
        guard let range = line.range(of: "(Charge: ") else { return nil }
        return Int(line[range.upperBound...].prefix { $0.isNumber })
    }

    // MARK: Measured periods (stored by the app)

    public struct PowerOffMark: Codable, Sendable, Equatable {
        public var date: Date
        public var remaining: Int?
        public var charge: Double?
        public var fullChargeCapacity: Int?
        /// The whole gauge (per-cell depth of discharge) for the drain detective.
        public var gauge: GaugeSnapshot?

        public init(date: Date, remaining: Int?, charge: Double?, fullChargeCapacity: Int?) {
            self.date = date
            self.remaining = remaining
            self.charge = charge
            self.fullChargeCapacity = fullChargeCapacity
        }
    }

    /// Turns a mark saved at power off into a measured period if the Mac has booted since.
    /// The reading must be taken soon after the boot (FixStat opening at login).
    public static func measured(mark: PowerOffMark, records: [(date: Date, isBoot: Bool)], now: Date,
                                remaining: Int?, charge: Double?) -> OffPeriod? {
        guard let boot = records.first(where: { $0.isBoot && $0.date > mark.date })?.date,
              now.timeIntervalSince(boot) < 900 else { return nil }
        return OffPeriod(source: .measured, shutdown: mark.date, boot: boot, chargeBefore: mark.charge,
                         chargeAfter: charge, remainingBefore: mark.remaining, remainingAfter: remaining,
                         fullChargeCapacity: mark.fullChargeCapacity)
    }
}
