import Foundation
import MacSensors

/// Localized texts for the originality check (window and PDF report).
public enum PartText {
    public static func verdict(_ verdict: PartCheck.Verdict) -> String {
        switch verdict {
        case .consistent: L("Consistent with a genuine part")
        case .suspicious: L("Suspicious — check the part")
        case .unknown: L("Not enough reference data to decide")
        }
    }

    /// The evidence line; items that check for data name the missing data when they warn.
    public static func item(_ id: String, status: PartCheck.Status = .pass) -> String {
        switch (id, status) {
        case ("manufacturerData", .warn): return L("Manufacturer data missing")
        case ("gaugeData", .warn): return L("Gauge learning data missing (Qmax, resistance, lifetime)")
        case ("gaugeData", .info): return L("Gauge learning data could not be read on this macOS version")
        case ("serial", .warn): return L("Pack serial number missing or too short")
        case ("adapter.serial", .warn): return L("Adapter serial number missing")
        case ("qmax", .warn): return L("Cell capacity (Qmax) far above the design capacity: made-up gauge data")
        case ("ref.gauge", .warn): return L("Gauge chip differs from genuine packs of this model")
        case ("ref.chemistry", .warn): return L("Chemistry ID differs from genuine packs of this model")
        case ("ref.chemistry", .info): return L("Chemistry ID not seen in genuine packs of this model yet")
        case ("ref.designCapacity", .warn): return L("Design capacity differs from this model's")
        case ("ref.cellCount", .warn): return L("Cell count differs from this model's")
        case ("ref.cellVendor", .info): return L("Cell maker not seen in genuine packs of this model yet")
        case ("adapter.manufacturer", .warn): return L("Manufacturer not reported as Apple")
        case ("adapter.nameWatts", .warn): return L("Rated power does not match the name")
        case ("ref.adapter.id", .warn): return L("Name differs from the Apple adapter with this ID")
        case ("ref.adapter.firmware", .info): return L("Firmware not seen in genuine adapters yet")
        case ("ref.adapter.profiles", .warn): return L("Power profiles differ from the genuine adapter")
        default: break
        }
        return switch id {
        case "ref.gauge": L("Gauge chip matches this model")
        case "ref.chemistry": L("Chemistry ID matches this model")
        case "ref.designCapacity": L("Design capacity matches this model")
        case "ref.cellCount": L("Cell count matches this model")
        case "ref.cellVendor": L("Cell maker seen in genuine packs of this model")
        case "noReference": L("No reference data for this model yet")
        case "gauge": L("Gauge chip")
        case "manufacturerData": L("Manufacturer data present")
        case "gaugeData": L("Gauge learning data present (Qmax, resistance, lifetime)")
        case "serial": L("Pack serial number present")
        case "qmax": L("Cell capacity (Qmax) plausible for the design capacity")
        case "cycleReset": L("Very low cycle count despite long operating time (reset or new pack?)")
        case "adapter.manufacturer": L("Manufacturer reported as Apple")
        case "adapter.nameWatts": L("Rated power matches the name")
        case "adapter.serial": L("Adapter serial number present")
        case "ref.adapter.id": L("Adapter ID matches a known Apple adapter")
        case "ref.adapter.firmware": L("Firmware seen in genuine adapters")
        case "ref.adapter.profiles": L("Power profiles match the genuine adapter")
        case "adapter.noReference": L("No reference data for this adapter yet")
        default: id
        }
    }

    public static func condition(_ value: String) -> String {
        switch value.lowercased() {
        case "good", "normal": L("Normal")
        case "check battery": L("Check battery")
        case "service recommended": L("Service recommended")
        default: value
        }
    }
}
