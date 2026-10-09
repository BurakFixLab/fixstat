import Foundation

/// The battery gauge at one moment: what the drain detective compares before and after a
/// sleep or a shutdown.
public struct GaugeSnapshot: Codable, Sendable, Equatable {
    public var date: Date
    /// Remaining capacity in mAh (`AppleRawCurrentCapacity`).
    public var remaining: Int?
    /// Displayed charge in %.
    public var charge: Int?
    public var externalConnected: Bool?
    public var isCharging: Bool?
    /// Per cell: maximum chemical capacity (mAh) and depth of discharge at the gauge's last
    /// open-circuit-voltage measurement (`DOD0`, 0…16384 = 0…100 %).
    public var cellQmax: [Int]?
    public var cellDOD0: [Int]?
    public var cellVoltages: [Int]?

    public init(date: Date, remaining: Int?, charge: Int?, externalConnected: Bool?, isCharging: Bool?,
                cellQmax: [Int]?, cellDOD0: [Int]?, cellVoltages: [Int]?) {
        self.date = date
        self.remaining = remaining
        self.charge = charge
        self.externalConnected = externalConnected
        self.isCharging = isCharging
        self.cellQmax = cellQmax
        self.cellDOD0 = cellDOD0
        self.cellVoltages = cellVoltages
    }

    public static func read(date: Date = Date()) -> GaugeSnapshot? {
        guard let properties = BatteryReader.properties() else { return nil }
        let data = properties.dict("BatteryData") ?? [:]
        let remaining = properties.int("AppleRawCurrentCapacity")
        let current = properties.int("CurrentCapacity"), maximum = properties.int("MaxCapacity")
        var charge: Int?
        if let current, let maximum, maximum > 0 { charge = Int((Double(current) / Double(maximum) * 100).rounded()) }
        return GaugeSnapshot(date: date, remaining: remaining, charge: charge,
                             externalConnected: properties.bool("ExternalConnected"),
                             isCharging: properties.bool("IsCharging"),
                             cellQmax: data.intArray("Qmax"), cellDOD0: data.intArray("DOD0"),
                             cellVoltages: data.intArray("CellVoltage"))
    }
}

/// How a loss of charge splits over the cells of the (series) pack. Every cell carries the
/// same load current, so charge drawn by the Mac leaves every cell alike; one cell losing
/// more than the others discharges by itself (or was bled by cell balancing).
public struct CellSplit: Codable, Sendable, Equatable {
    /// Loss per cell in mAh beyond the smallest cell loss.
    public var extra: [Double]
    /// Cell with the highest state of charge at the start (the one balancing would bleed).
    public var highestAtStart: Int

    public static let dodFull = 16384.0

    /// nil when the gauge took no new open-circuit measurement in between (DOD0 unchanged)
    /// or the cell data is missing.
    public static func between(_ a: GaugeSnapshot, _ b: GaugeSnapshot) -> CellSplit? {
        guard let dodA = a.cellDOD0, let dodB = b.cellDOD0, let qmax = b.cellQmax ?? a.cellQmax,
              dodA.count == dodB.count, dodA.count == qmax.count, dodA.count >= 2, dodA != dodB else { return nil }
        let loss = dodA.indices.map { Double(dodB[$0] - dodA[$0]) / dodFull * Double(qmax[$0]) }
        let common = loss.min() ?? 0
        let highest = dodA.indices.min { dodA[$0] < dodA[$1] } ?? 0
        return CellSplit(extra: loss.map { $0 - common }, highestAtStart: highest)
    }
}

/// One sleep (or shutdown) between two gauge snapshots.
public struct DrainSegment: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case sleep, off }

    public var kind: Kind
    public var start: GaugeSnapshot
    public var end: GaugeSnapshot

    public init(kind: Kind, start: GaugeSnapshot, end: GaugeSnapshot) {
        self.kind = kind
        self.start = start
        self.end = end
    }

    public var hours: Double { end.date.timeIntervalSince(start.date) / 3600 }

    /// On battery the whole time: no adapter at either end and not charging.
    public var onBattery: Bool {
        start.externalConnected == false && end.externalConnected == false
            && start.isCharging != true && end.isCharging != true
    }

    /// Charge lost in mAh (nil when not measurable).
    public var drain: Double? {
        guard let a = start.remaining, let b = end.remaining else { return nil }
        return Double(a - b)
    }

    /// Mean current in mA.
    public var milliamps: Double? {
        guard let drain, hours > 0 else { return nil }
        return drain / hours
    }

    public var cells: CellSplit? { CellSplit.between(start, end) }
}

/// The verdict of the drain detective: drain while asleep and while shut down, what woke
/// the Mac, and whether the loss looks like software, the battery or the board.
public struct DrainReport: Sendable, Equatable {
    public enum Level: Int, Comparable, Sendable {
        case normal, elevated, high
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Summary: Sendable, Equatable {
        /// Median mean current of the usable segments (mA).
        public var milliamps: Double
        public var worst: Double
        public var segments: Int
        public var hours: Double
        public var level: Level
    }

    public enum Conclusion: Equatable, Sendable {
        /// No usable measurement yet.
        case noData
        case normal
        /// Dark wakes explain the drain.
        case software
        /// One cell loses charge by itself.
        case battery(cell: Int)
        /// High drain without wakes: a leak on rails that stay powered. `alwaysOn`: also
        /// while shut down (G3H / AON rails or the pack); false: only while asleep (rails
        /// powered in sleep, a device that stays powered); nil: no shutdown measurement.
        case hardware(alwaysOn: Bool?)
    }

    public struct CellFinding: Sendable, Equatable {
        public var cell: Int
        public var extraMilliampHours: Double
        /// The cell had the highest charge at the start: the extra loss may be balancing.
        public var maybeBalancing: Bool
    }

    public var sleep: Summary?
    public var off: Summary?
    /// Dark wakes during the usable sleep segments.
    public var darkWakes: Int
    public var darkWakeSeconds: Int
    public var sleepSeconds: Int
    public var cellFindings: [CellFinding]
    /// Processes that held long sleep-preventing assertions (from the log): they keep the Mac
    /// awake ("it does not go to sleep"), they do not drain a sleeping Mac.
    public var preventers: [String]
    /// pmset settings that let the Mac wake while asleep and are on.
    public var wakeSettings: [String]
    public var conclusion: Conclusion

    /// Rough guides until bench reference values per model exist (mA).
    public static let sleepElevated = 20.0, sleepHigh = 50.0
    public static let offElevated = 10.0, offHigh = 30.0
    /// Shortest segment that counts (gauge resolution and the open-circuit update need time).
    public static let minimumHours = 1.0
    /// Extra cell loss that counts as self-discharge: at least this many mAh and 0.5 % of Qmax.
    public static let cellExtraMinimum = 15.0

    static func summary(_ segments: [DrainSegment], elevated: Double, high: Double) -> Summary? {
        let values = segments.compactMap(\.milliamps).filter { $0 >= 0 }.sorted()
        guard !values.isEmpty else { return nil }
        let median = values.count % 2 == 1 ? values[values.count / 2]
            : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
        let level: Level = median >= high ? .high : median >= elevated ? .elevated : .normal
        return Summary(milliamps: median, worst: values.last ?? median, segments: values.count,
                       hours: segments.map(\.hours).reduce(0, +), level: level)
    }

    public static func make(segments: [DrainSegment], analysis: SleepAnalysis?) -> DrainReport {
        let usable = segments.filter { $0.onBattery && $0.hours >= minimumHours && $0.drain != nil }
        let sleeps = usable.filter { $0.kind == .sleep }
        let offs = usable.filter { $0.kind == .off }

        var darkWakes = 0, darkSeconds = 0
        for segment in sleeps {
            let inside = (analysis?.darkWakes ?? []).filter { $0.date > segment.start.date && $0.date < segment.end.date }
            darkWakes += inside.count
            darkSeconds += inside.compactMap(\.duration).reduce(0, +)
        }
        let sleepSeconds = Int(sleeps.map(\.hours).reduce(0, +) * 3600)

        var cellFindings: [CellFinding] = []
        for segment in usable {
            guard let split = segment.cells, let qmax = segment.end.cellQmax ?? segment.start.cellQmax else { continue }
            for (cell, extra) in split.extra.enumerated()
            where extra >= cellExtraMinimum && extra >= 0.005 * Double(qmax[cell]) {
                if let index = cellFindings.firstIndex(where: { $0.cell == cell }) {
                    cellFindings[index].extraMilliampHours = max(cellFindings[index].extraMilliampHours, extra)
                } else {
                    cellFindings.append(CellFinding(cell: cell, extraMilliampHours: extra,
                                                    maybeBalancing: cell == split.highestAtStart))
                }
            }
        }

        let preventers = (analysis?.preventers ?? []).filter { $0.longestSeconds >= 600 }.map(\.process)
        let settings = analysis?.settings ?? [:]
        let wakeSettings = ["powernap", "tcpkeepalive", "womp", "proximitywake"].filter { settings[$0] == "1" }

        let sleep = summary(sleeps, elevated: sleepElevated, high: sleepHigh)
        let off = summary(offs, elevated: offElevated, high: offHigh)
        let selfDischarging = cellFindings.first { !$0.maybeBalancing }

        let conclusion: Conclusion
        if sleep == nil && off == nil {
            conclusion = selfDischarging.map { .battery(cell: $0.cell) } ?? .noData
        } else if let sleep, sleep.level > .normal {
            // More than two dark wakes per hour or over 10 % of the time awake: software.
            let busy = sleepSeconds > 0 && (Double(darkWakes) / (Double(sleepSeconds) / 3600) > 2
                || Double(darkSeconds) > 0.1 * Double(sleepSeconds))
            // Assertions only delay sleep; asleep, the dark wakes are what costs charge.
            if busy {
                conclusion = .software
            } else if let cell = selfDischarging {
                conclusion = .battery(cell: cell.cell)
            } else {
                conclusion = .hardware(alwaysOn: off.map { $0.level > .normal })
            }
        } else if let off, off.level > .normal {
            conclusion = selfDischarging.map { .battery(cell: $0.cell) } ?? .hardware(alwaysOn: true)
        } else {
            conclusion = selfDischarging.map { .battery(cell: $0.cell) } ?? .normal
        }
        return DrainReport(sleep: sleep, off: off, darkWakes: darkWakes, darkWakeSeconds: darkSeconds,
                           sleepSeconds: sleepSeconds, cellFindings: cellFindings, preventers: preventers,
                           wakeSettings: wakeSettings, conclusion: conclusion)
    }
}
