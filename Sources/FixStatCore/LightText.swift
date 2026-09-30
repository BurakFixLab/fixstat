import Foundation
import MacSensors

/// A sensor value together with its unit (lux or raw).
public struct LightReadingValue: Equatable {
    public var value: Double
    public var source: AmbientLightSensor.Source

    public init(value: Double, source: AmbientLightSensor.Source) {
        self.value = value
        self.source = source
    }
}

public enum LightText {
    public static func value(_ v: LightReadingValue) -> String {
        switch v.source {
        case .lux: Format.number(v.value) + "\u{00A0}lx"
        case .raw: L("%@ (raw)", Format.number(v.value))
        }
    }

    public static func value(_ v: LightReadingValue?) -> String { v.map { value($0) } ?? "–" }

    public static func value(_ r: AmbientLightSensor.Reading) -> String {
        value(LightReadingValue(value: r.value, source: r.source))
    }

    public static func finding(_ f: LightCheck.Finding) -> String {
        switch f {
        case .notFound:
            L("No ambient light sensor found. On MacBooks this points to the camera board or the display cable.")
        case .unstable:
            L("The reading jumps in steady light — screen brightness would flicker by itself.")
        case .doesNotDarken:
            L("Covering the sensor does not lower the value: it reads bright all the time (display always bright, keyboard light stays off).")
        case .doesNotBrighten:
            L("The flashlight reached the sensor but the value stayed low: it reads dark (display dims by itself).")
        case .frozen:
            L("The value never changes: the sensor reading is frozen.")
        case .noLightSeen:
            L("The flashlight was not seen. Hold it closer to the camera.")
        case .cameraDidNotSeeLight:
            L("The sensor saw the flashlight but the camera stayed dark — check the camera as well.")
        }
    }
}
