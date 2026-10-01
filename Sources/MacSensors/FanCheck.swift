import Foundation

/// Evaluates the fans during the hardware check's fan test. FixStat never sets fan speeds
/// (no SMC writes), so the test puts load on the Mac and checks that every fan follows the
/// speed the system asks for (`F<n>Tg`): a fan that does not turn while it should, or that
/// stays well below its target, is faulty (bearing, connector, blocked fan, fan driver).
public struct FanCheck: Sendable, Equatable {
    public struct Fan: Sendable, Equatable {
        public var index: Int
        /// First reading, before the load.
        public var idle: Double?
        public var idleTarget: Double?
        public var minimum: Double?
        public var maximum: Double?
        public var peak: Double = 0
        public var peakTarget: Double = 0
        /// Consecutive seconds with a target but (almost) no rotation / well below the target.
        public var stalledSeconds: Double = 0
        public var lowSeconds: Double = 0
        public var worstStall: Double = 0
        public var worstLow: Double = 0
        /// Target and speed when the shortfall was largest.
        public var lowTarget: Double?
        public var lowActual: Double?
    }

    public enum Verdict: Equatable, Sendable {
        /// Every fan followed its target and the system asked for more speed.
        case passed
        /// The fan does not turn although the system asks for `target` rpm.
        case stalled(fan: Int, target: Double)
        /// The fan stays well below its target.
        case belowTarget(fan: Int, actual: Double, target: Double)
        /// No fan was asked to speed up (the Mac stayed cool enough): no verdict.
        case notAsked
    }

    /// A target counts as "asked to turn" from this speed on.
    public static let activeTarget = 500.0
    /// Below this the fan counts as standing still.
    public static let stoppedBelow = 100.0
    /// Below this share of the target the fan counts as too slow.
    public static let lowShare = 0.7
    public static let stallSeconds = 8.0
    public static let lowSecondsLimit = 15.0
    /// The target must rise this much above its idle value for the test to say anything.
    public static let speedUp = 300.0

    public private(set) var fans: [Fan] = []

    public init() {}

    public mutating func add(_ readings: [FanReading], seconds: Double = 1) {
        for reading in readings {
            if !fans.contains(where: { $0.index == reading.index }) {
                fans.append(Fan(index: reading.index, idle: reading.actual, idleTarget: reading.target,
                                minimum: reading.minimum, maximum: reading.maximum))
            }
            guard let i = fans.firstIndex(where: { $0.index == reading.index }) else { continue }
            let actual = reading.actual ?? 0
            let target = reading.target ?? 0
            fans[i].peak = max(fans[i].peak, actual)
            fans[i].peakTarget = max(fans[i].peakTarget, target)
            if target >= Self.activeTarget && actual < Self.stoppedBelow {
                fans[i].stalledSeconds += seconds
                fans[i].worstStall = max(fans[i].worstStall, fans[i].stalledSeconds)
            } else {
                fans[i].stalledSeconds = 0
            }
            if target >= Self.activeTarget && actual < Self.lowShare * target {
                fans[i].lowSeconds += seconds
                if fans[i].lowSeconds > fans[i].worstLow {
                    fans[i].worstLow = fans[i].lowSeconds
                    fans[i].lowTarget = target
                    fans[i].lowActual = actual
                }
            } else {
                fans[i].lowSeconds = 0
            }
        }
    }

    public var verdict: Verdict {
        for fan in fans where fan.worstStall >= Self.stallSeconds {
            return .stalled(fan: fan.index, target: fan.peakTarget)
        }
        for fan in fans where fan.worstLow >= Self.lowSecondsLimit {
            return .belowTarget(fan: fan.index, actual: fan.lowActual ?? 0, target: fan.lowTarget ?? 0)
        }
        let askedUp = fans.contains { $0.peakTarget >= max($0.idleTarget ?? 0, $0.minimum ?? 0) + Self.speedUp }
        return askedUp ? .passed : .notAsked
    }
}
