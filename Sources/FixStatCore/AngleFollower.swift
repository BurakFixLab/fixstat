import Foundation

/// Eases a shown angle towards the sensor's (critically damped, ~60 ms), so integer steps and the
/// gaps between sensor reports do not show. Called once per display frame (both interfaces).
public final class AngleFollower {
    private var shown: Double?
    private var last: Date?

    public init() {}

    public func value(at date: Date, target: Double?) -> Double? {
        guard let target = target else { return shown }
        defer { last = date }
        guard let current = shown, let last = last else {
            shown = target
            return target
        }
        let elapsed = min(max(date.timeIntervalSince(last), 0), 0.1)
        let next = current + (target - current) * (1 - exp(-elapsed / 0.06))
        shown = abs(next - target) < 0.05 ? target : next
        return shown
    }
}
