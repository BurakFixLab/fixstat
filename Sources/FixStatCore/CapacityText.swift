import Foundation
import MacSensors

public enum CapacityText {
    public static func finding(_ f: CapacityResult.Finding) -> String {
        switch f {
        case .tooShort:
            L("The charge fell by less than %@; the capacity figures are only rough.", Format.percent(CapacityResult.minimumPercentDrop))
        case .capacityBelowGauge(let ratio):
            L("The battery delivered only %@ of the capacity its gauge reports. The gauge overstates the battery (common with reset or non-genuine gauges).", Format.percent(ratio * 100))
        case .gaugeMiscount(let ratio):
            L("The gauge's remaining capacity changed differently from the charge delivered (%@). The gauge counts incorrectly or needs calibration.", Format.percent(ratio * 100))
        case .shutdownAtCharge(let percent):
            L("The Mac turned off while the battery still showed %@. The battery cannot deliver the charge its gauge reports — typical for a weak cell or a voltage collapse under load.", Format.percent(percent))
        case .weakCell(let cell, let spread):
            L("Cell %lld sags under load: cell voltages differ by up to %@.", cell, Format.millivolts(spread))
        }
    }

    public static func stopReason(_ r: CapacityResult.StopReason) -> String {
        switch r {
        case .targetReached: L("Stop level reached")
        case .stopped: L("Stopped")
        case .adapterConnected: L("Power adapter connected")
        case .tooHot: L("Battery too hot")
        case .batteryEmpty: L("Battery empty: the Mac went to sleep or turned off")
        case .unexpectedShutdown: L("The Mac turned off unexpectedly")
        }
    }

    public static func rows(_ r: CapacityResult) -> [(String, String)] {
        var rows: [(String, String)] = [
            (L("Result"), stopReason(r.stopReason)),
            (L("Charge"), [r.startPercent, r.endPercent].map { $0.map { Format.percent($0) } ?? "–" }
                .joined(separator: " → ")),
            (L("Duration"), Format.duration(r.duration)),
            (L("Delivered"), Format.milliampHours(Int(r.deliveredMAh)) + " · " + Format.watthours(r.deliveredWh)),
        ]
        if let w = r.averageWatts { rows.append((L("Average power"), Format.watts(w, digits: 1))) }
        if let e = r.extrapolatedCapacity {
            rows.append((L("Measured capacity (extrapolated to 100 %)"), Format.milliampHours(Int(e))))
        }
        if let f = r.fullChargeCapacity {
            rows.append((L("Gauge full charge capacity"), Format.milliampHours(f)
                         + (r.capacityAgreement.map { " · " + L("measured %@", Format.percent($0 * 100)) } ?? "")))
        }
        if let d = r.designCapacity { rows.append((L("Design capacity"), Format.milliampHours(d))) }
        if let g = r.gaugeAgreement {
            rows.append((L("Gauge agreement"), Format.percent(g * 100)))
        }
        if let res = r.packResistance {
            rows.append((L("Pack resistance (load step)"), Format.number(res) + "\u{00A0}mΩ"))
        }
        if let spread = r.maxCellSpread {
            rows.append((L("Largest cell difference under load"), Format.millivolts(spread)
                         + (r.weakestCell.map { " · " + L("lowest: cell %lld", $0) } ?? "")))
        }
        if let v = r.lowestVoltage { rows.append((L("Lowest voltage"), Format.volts(millivolts: v))) }
        if let t = r.highestTemperature { rows.append((L("Highest temperature"), Format.temperature(t))) }
        return rows
    }
}
