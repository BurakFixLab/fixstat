import Foundation
import MacSensors

/// Texts of the power analysis window (both interfaces).
public enum PowerText {
    /// System totals in display order: (title, watts).
    public static func totals(_ totals: [String: Double]) -> [(String, String)] {
        [("PSTR", L("System total")), ("PDTR", L("Power adapter input")), ("PPBR", L("Battery rail"))]
            .compactMap { key, title in totals[key].map { (title, Format.watts($0, digits: 2)) } }
    }

    /// SoC component name for an IOReport channel ("CPU Energy" → "CPU").
    public static func component(_ name: String) -> String {
        switch name {
        case "CPU Energy": return L("CPU")
        case "GPU Energy", "GPU": return L("GPU")
        case "ANE Energy", "ANE": return L("Neural Engine")
        case "DRAM Energy", "DRAM": return L("Memory (DRAM)")
        case "ECPU", "EACC_CPU": return L("Efficiency cluster")
        case "PCPU", "PACC_CPU": return L("Performance cluster")
        default: break
        }
        if let n = number(in: name, pattern: "^PACC([0-9]+)_CPU$") { return L("Performance cluster %lld", n + 1) }
        if let n = number(in: name, pattern: "^EACC([0-9]+)_CPU$") { return L("Efficiency cluster %lld", n + 1) }
        return name.hasSuffix(" Energy") ? String(name.dropLast(7)) : name
    }

    /// Components, highest first: (name, watts).
    public static func components(_ list: [ComponentPower]) -> [[String]] {
        list.sorted { $0.watts > $1.watts }.map { [component($0.name), Format.watts($0.watts, digits: 2)] }
    }

    /// "PMU buck 0", "PMU2 LDO 4" from the key suffix; known single rails by name; else the key.
    public static func rail(_ name: String) -> String {
        switch name {
        case "BLR": return L("Display backlight")
        case "KBC": return L("Keyboard backlight")
        case "PBR": return L("Battery rail")
        case "b0f": return L("Battery pack")
        case "D0R": return L("DC in")
        default: break
        }
        let chars = Array(name)
        if chars.count == 3, chars[0] == "P" || chars[0] == "R", chars[2] == "b" || chars[2] == "l" {
            let channel = String(chars[1]).uppercased()
            switch (chars[0], chars[2]) {
            case ("P", "b"): return L("PMU buck %@", channel)
            case ("P", _): return L("PMU LDO %@", channel)
            case (_, "b"): return L("PMU2 buck %@", channel)
            default: return L("PMU2 LDO %@", channel)
            }
        }
        return name
    }

    /// A rail that carries current (or power) now.
    public static func isActive(_ rail: PowerRail) -> Bool {
        (rail.amps ?? 0) > 0.001 || (rail.watts ?? 0) > 0.001
    }

    /// Active rails, highest power first: name, key, V, A, W. `PBR` is left out: its power is
    /// the battery rail total shown above (`PPBR`).
    public static func rails(_ list: [PowerRail]) -> [[String]] {
        list.filter { isActive($0) && $0.name != "PBR" }
            .sorted { ($0.watts ?? 0, $0.amps ?? 0) > ($1.watts ?? 0, $1.amps ?? 0) }
            .map { rail in
                [Self.rail(rail.name), rail.name,
                 rail.volts.map { Format.volts(millivolts: Int(($0 * 1000).rounded()), digits: 3) } ?? "–",
                 rail.amps.map { Format.milliamps(Int(($0 * 1000).rounded()), signed: false) } ?? "–",
                 rail.watts.map { Format.watts($0, digits: 3) } ?? "–"]
            }
    }

    /// "12 rails carry no current now."
    public static func idleRails(_ list: [PowerRail]) -> String? {
        let idle = list.filter { !isActive($0) && $0.name != "PBR" }.count
        return idle > 0 ? L("%lld rails carry no current now.", idle) : nil
    }

    public static var explanation: String {
        L("Read from the SMC and IOReport every second, without administrator rights. Rails are the outputs of the power management chips; which part a rail feeds differs per board. A rail that draws clearly more current at idle than on a good Mac of the same model points to a leak or a short on that rail.")
    }

    static func number(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return Int(text[range])
    }
}
