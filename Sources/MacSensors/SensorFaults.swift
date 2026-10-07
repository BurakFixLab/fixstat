import Foundation

/// A temperature sensor that reads like a broken sensor or connection.
public struct SensorFault: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Far below any real temperature (≤ −20 °C): open circuit.
        case open
        /// Far above any real temperature (> 130 °C): short circuit.
        case short
        /// The SMC's "no reading" value (−127) or nothing at all.
        case noReading
        /// Exactly the same value the whole time while the sensors around it moved.
        case frozen
        /// Plausible, but much colder than the rest of the Mac.
        case tooCold
        /// Named by this model's map but not published by the Mac at all.
        case missing
        /// A CPU / GPU sensor that hardly moved under load while the others of its group heated up.
        case noResponse
    }

    /// `SensorDescriptor.uid`.
    public var uid: String
    /// Raw SMC key or HID name.
    public var label: String
    /// Sensor id from the map (localized by the app), nil when unnamed.
    public var id: String?
    public var group: SensorMap.Group
    public var kind: Kind
    /// Typical value while observed (median), if any.
    public var value: Double?
    /// The sensor is named by this model's or this chip's entry, so it really exists on this
    /// Mac. Pattern matches are guesses: such a key may simply not be fitted on this model.
    public var known: Bool

    public init(uid: String, label: String, id: String?, group: SensorMap.Group, kind: Kind, value: Double?, known: Bool) {
        self.uid = uid
        self.label = label
        self.id = id
        self.group = group
        self.kind = kind
        self.value = value
        self.known = known
    }
}

/// Finds broken temperature sensors in a series of samples (one value per sensor per second).
///
/// Only named sensors are judged: many SMC `T…` keys are not temperatures at all. Readings
/// that come and go are tolerated (Intel SMCs answer −127 until a sensor was read once), so
/// a rule must hold for most of the samples.
public enum SensorFaultDetector {
    public struct Sensor {
        public var descriptor: SensorDescriptor
        public var resolved: ResolvedSensor
        public init(descriptor: SensorDescriptor, resolved: ResolvedSensor) {
            self.descriptor = descriptor
            self.resolved = resolved
        }
    }

    /// Share of samples a rule must hold for.
    public static let majority = 0.8
    /// A known sensor reading this cold is open: Apple Silicon PMU channels without an NTC read
    /// about −22 °C. A pattern match (maybe not fitted on this model) must read colder still.
    public static let openBelow = -20.0
    public static let openBelowGuessed = -30.0
    public static let shortAbove = 130.0
    public static let noReadingValue = -127.0
    /// A frozen sensor needs this long a window and peers that moved at least `peerSwing`.
    public static let frozenMinimumSeconds = 60.0
    public static let peerSwing = 3.0
    /// "Too cold": below `coldBelow` while the Mac's board / chassis sensors are at least `warmMac`.
    public static let coldBelow = 10.0
    public static let warmMac = 25.0

    /// - Parameters:
    ///   - sensors: the named, not ignored sensors.
    ///   - series: per sensor (same order), its values over time (nil: not read).
    ///   - seconds: length of the observation.
    public static func detect(_ sensors: [Sensor], series: [[Double?]], seconds: Double) -> [SensorFault] {
        guard sensors.count == series.count else { return [] }
        func plausible(_ v: Double) -> Bool { SMC.plausibleTemperatureRange.contains(v) }
        // Die zones of CPU / GPU clusters and SoC blocks (ANE, ISP, …) read a constant while
        // their block is power gated (M1: ANE and ISP 30.0 °C).
        func isDie(_ s: Sensor) -> Bool {
            s.resolved.group == .cpu || s.resolved.group == .gpu || s.resolved.id.hasPrefix("soc.")
        }
        // Apple Silicon `TV..` keys are estimates macOS computes (virtual skin / ambient).
        func isVirtual(_ s: Sensor) -> Bool { s.descriptor.key?.hasPrefix("TV") == true }
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func active(_ s: Sensor, _ values: [Double?]) -> [Double] {
            values.compactMap { $0 }.filter(plausible).filter { !isDie(s) || $0 >= SMC.minimumActiveDieTemperature }
        }

        // Swing (max − min) per group, and how warm the board / chassis sensors are.
        var swing: [SensorMap.Group: Double] = [:]
        var boardMedians: [Double] = []
        var groupSize: [SensorMap.Group: Int] = [:]
        for (sensor, values) in zip(sensors, series) where !isVirtual(sensor) {
            groupSize[sensor.resolved.group, default: 0] += 1
            let good = active(sensor, values)
            guard let lo = good.min(), let hi = good.max() else { continue }
            swing[sensor.resolved.group] = max(swing[sensor.resolved.group] ?? 0, hi - lo)
            if !isDie(sensor), let m = median(good) { boardMedians.append(m) }
        }
        let macWarmth = median(boardMedians)
        let anySwing = swing.values.max() ?? 0

        var faults: [SensorFault] = []
        for (sensor, values) in zip(sensors, series) where !isVirtual(sensor) {
            let count = Double(values.count)
            guard count > 0 else { continue }
            let read = values.compactMap { $0 }
            func share(_ test: (Double) -> Bool) -> Double { Double(read.filter(test).count) / count }
            let known = sensor.resolved.level != .pattern
            func fault(_ kind: SensorFault.Kind, _ value: Double?) {
                faults.append(SensorFault(uid: sensor.descriptor.uid, label: sensor.descriptor.rawLabel,
                                          id: sensor.resolved.id, group: sensor.resolved.group, kind: kind,
                                          value: value, known: known))
            }
            // A guessed key that never reads may simply not exist on this model (TC3C / TC4C on a
            // dual-core Intel CPU), so "no reading" counts only for known sensors.
            if share({ $0 == noReadingValue }) + (1 - Double(read.count) / count) >= majority {
                if known { fault(.noReading, nil) }
                continue
            }
            let openLimit = known ? openBelow : openBelowGuessed
            let open = read.filter { $0 <= openLimit && $0 != noReadingValue }
            if Double(open.count) / count >= majority {
                fault(.open, median(open))
                continue
            }
            let short = read.filter { $0 > shortAbove }
            if Double(short.count) / count >= majority {
                fault(.short, median(short))
                continue
            }
            if isDie(sensor) { continue }
            let good = read.filter(plausible)
            guard Double(good.count) / count >= majority, let typical = median(good) else { continue }
            if seconds >= frozenMinimumSeconds, good.count >= 30, let lo = good.min(), let hi = good.max(), hi == lo {
                // Peers in the same group, or the whole Mac when the group has no other sensor.
                let peers = (groupSize[sensor.resolved.group] ?? 0) > 1 ? swing[sensor.resolved.group] ?? 0 : anySwing
                if peers >= peerSwing {
                    fault(.frozen, typical)
                    continue
                }
            }
            if known, let warmth = macWarmth, warmth >= warmMac, typical < coldBelow {
                fault(.tooCold, typical)
            }
        }
        return faults
    }

    // MARK: Missing sensors

    /// Sensors this model's map names but the Mac does not publish (a flex cable or a part not
    /// connected). Only model entries, and only board, chassis and battery sensors: CPU / GPU
    /// zones differ between binned chips of one model (8- or 10-core GPU) and NAND channels
    /// with the SSD size.
    public static let missingGroups: Set<SensorMap.Group> = [.other, .chassis, .battery]

    public static func missing(map: SensorMap, model: String, present: [SensorDescriptor],
                               hasBattery: Bool) -> [SensorFault] {
        guard let entry = map.models[model] else { return [] }
        let names = Set(present.flatMap { [$0.key, $0.hidName].compactMap { $0 } })
        return entry.sensors.compactMap { sensor in
            guard !names.contains(sensor.key), missingGroups.contains(sensor.group),
                  hasBattery || sensor.group != .battery else { return nil }
            return SensorFault(uid: "missing:" + sensor.key, label: sensor.key, id: sensor.id, group: sensor.group,
                               kind: .missing, value: nil, known: true)
        }
    }

    // MARK: Under load

    /// A group must warm up at least this much (median) for its sensors to be judged…
    public static let loadGroupRise = 6.0
    /// …and a sensor that rose less than this share of the group's median rise (and under
    /// `loadMinimumRise`) does not follow the load.
    public static let loadRiseShare = 0.2
    public static let loadMinimumRise = 1.5

    /// CPU / GPU sensors that do not follow a load. `before`: samples just before the load;
    /// `during`: samples under load (per sensor, values over time).
    public static func unresponsive(_ sensors: [Sensor], before: [[Double?]], during: [[Double?]],
                                    groups: Set<SensorMap.Group> = [.cpu, .gpu]) -> [SensorFault] {
        guard sensors.count == before.count, sensors.count == during.count else { return [] }
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func active(_ values: [Double?]) -> [Double] {
            values.compactMap { $0 }.filter { SMC.plausibleTemperatureRange.contains($0) && $0 >= SMC.minimumActiveDieTemperature }
        }
        // Rise per sensor: the last quarter under load against the samples before it.
        var rises: [Int: Double] = [:]
        for index in sensors.indices where groups.contains(sensors[index].resolved.group) {
            let end = active(Array(during[index].suffix(max(3, during[index].count / 4))))
            guard let start = median(active(before[index])), let hot = median(end) else { continue }
            rises[index] = hot - start
        }
        var faults: [SensorFault] = []
        for group in groups.sorted(by: { $0.rawValue < $1.rawValue }) {
            let members = rises.filter { sensors[$0.key].resolved.group == group }
            guard members.count >= 2, let typical = median(Array(members.values)), typical >= loadGroupRise else { continue }
            for (index, rise) in members.sorted(by: { $0.key < $1.key })
            where rise < loadMinimumRise && rise < typical * loadRiseShare {
                let sensor = sensors[index]
                // A sensor that reads plausibly while its neighbours heat up exists on this Mac,
                // even when its name is only guessed from the key.
                faults.append(SensorFault(uid: sensor.descriptor.uid, label: sensor.descriptor.rawLabel,
                                          id: sensor.resolved.id, group: group, kind: .noResponse, value: rise,
                                          known: true))
            }
        }
        return faults
    }
}
