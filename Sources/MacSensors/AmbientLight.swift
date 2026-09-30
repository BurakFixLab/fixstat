import CMacSensors
import Foundation

/// Ambient light sensor (the sensor next to the camera that drives automatic brightness).
///
/// Apple Silicon reports lux through the HID event system; Intel MacBooks report two raw
/// channels through AppleLMUController (not lux, but proportional to light). Read-only.
public enum AmbientLightSensor {
    public enum Source: String, Codable, Sendable { case lux, raw }

    public struct Reading: Equatable, Sendable {
        public var value: Double
        public var source: Source
    }

    public static func read() -> Reading? {
        var lux = 0.0
        if FSAmbientLightLux(&lux) { return Reading(value: lux, source: .lux) }
        var left: UInt64 = 0, right: UInt64 = 0
        if FSLMUReadChannels(&left, &right) { return Reading(value: Double(left + right) / 2, source: .raw) }
        return nil
    }

    /// macOS setting "Automatically adjust brightness" (nil if unknown). A display that
    /// dims by itself with a healthy sensor is often just this setting.
    public static var automaticBrightnessEnabled: Bool? {
        let domain = "/Library/Preferences/com.apple.iokit.AmbientLightSensor" as CFString
        guard let value = CFPreferencesCopyValue("Automatic Display Enabled" as CFString, domain,
                                                 kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
                ?? CFPreferencesCopyAppValue("Automatic Display Enabled" as CFString, domain) else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}

/// The guided ambient light test: readings in normal light, with the sensor covered by a
/// finger and with a flashlight on it. The camera next to the sensor tells whether the
/// light really was there, so "no flashlight" and "broken sensor" are told apart.
public enum LightCheck {
    public enum Finding: Equatable, Sendable {
        case notFound
        /// Readings jump in steady light (screen brightness would flicker).
        case unstable(spread: Double, mean: Double)
        /// Covering the sensor does not lower the value (reads bright all the time).
        case doesNotDarken(room: Double, covered: Double)
        /// Light was on the sensor (camera saw it) but the value stayed low (reads dark).
        case doesNotBrighten(room: Double, bright: Double)
        /// Exactly the same value in every step: the reading is frozen.
        case frozen(Double)
        /// Neither sensor nor camera saw the flashlight: repeat closer to the camera.
        case noLightSeen
        /// The sensor saw the flashlight but the camera stayed dark: check the camera.
        case cameraDidNotSeeLight
    }

    public enum Verdict: Equatable, Sendable { case passed, failed, repeatStep }

    /// Camera brightness (0…1) from which the flashlight counts as present.
    public static let cameraBrightThreshold = 0.6

    public static func evaluate(room: [Double], covered: [Double], bright: [Double],
                                cameraBrightness: Double?) -> (verdict: Verdict, findings: [Finding]) {
        guard let roomMean = mean(room), let coveredMin = covered.min(), let brightMax = bright.max() else {
            return (.failed, [.notFound])
        }
        var findings: [Finding] = []
        let all = room + covered + bright
        if Set(all).count == 1, let value = all.first {
            return (.failed, [.frozen(value)])
        }
        if let lo = room.min(), let hi = room.max(), hi - lo > max(10, 0.4 * roomMean) {
            findings.append(.unstable(spread: hi - lo, mean: roomMean))
        }
        let darkens = coveredMin <= max(2, 0.25 * roomMean)
        if !darkens { findings.append(.doesNotDarken(room: roomMean, covered: coveredMin)) }

        let brightens = brightMax >= max(3 * roomMean, roomMean + 50)
        let cameraSawLight = cameraBrightness.map { $0 >= cameraBrightThreshold }
        if !brightens {
            if cameraSawLight == false {
                // The light was not on the sensor: nothing can be said about it yet.
                return (.repeatStep, findings + [.noLightSeen])
            }
            findings.append(.doesNotBrighten(room: roomMean, bright: brightMax))
        } else if cameraSawLight == false {
            findings.append(.cameraDidNotSeeLight)
        }
        let failed = findings.contains { finding in
            if case .cameraDidNotSeeLight = finding { return false }
            return true
        }
        return (failed ? .failed : .passed, findings)
    }

    public static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
