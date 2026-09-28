import Foundation
import MacSensors

/// Display names for sensors.
///
/// The sensor map id is the localization key: `cpu.pcluster.3` looks up
/// "sensor.cpu.pcluster.n" (a format with one integer, e.g. "Performance
/// cluster %lld"), `board.charger` looks up "sensor.board.charger".
/// A user-defined name wins; unmapped sensors show their raw name.
enum SensorNames {
    static func name(for sensor: DisplaySensor) -> String {
        if let custom = sensor.resolved?.name, !custom.isEmpty { return custom }
        if let id = sensor.resolved?.id, let name = localizedName(id: id) { return name }
        return sensor.descriptor.hidName ?? sensor.descriptor.rawLabel
    }

    /// The name from the string catalog without any user override.
    static func defaultName(for sensor: DisplaySensor) -> String {
        sensor.resolved.flatMap { localizedName(id: $0.id) }
            ?? sensor.descriptor.hidName ?? sensor.descriptor.rawLabel
    }

    static func localizedName(id: String) -> String? {
        let parts = id.split(separator: ".")
        let missing = "\u{0}"
        if parts.count > 1, let last = parts.last, let index = Int(last) {
            let key = "sensor." + parts.dropLast().joined(separator: ".") + ".n"
            let format = Bundle.main.localizedString(forKey: key, value: missing, table: nil)
            guard format != missing else { return nil }
            return String(format: format, locale: .current, index)
        }
        let name = Bundle.main.localizedString(forKey: "sensor." + id, value: missing, table: nil)
        return name == missing ? nil : name
    }
}
