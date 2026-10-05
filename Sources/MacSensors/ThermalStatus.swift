import Foundation

/// How hard macOS holds the CPU back for heat: the system thermal state everywhere, and on
/// Intel the CPU speed limit from `pmset -g therm` (100 % = no limit). No root needed.
public struct ThermalStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case nominal, fair, serious, critical
    }

    public var state: State
    /// Intel: allowed CPU speed (%); below 100 the CPU is throttled.
    public var cpuSpeedLimit: Int?
    /// Intel: share of the CPUs the scheduler may use (%).
    public var schedulerLimit: Int?

    public init(state: State, cpuSpeedLimit: Int? = nil, schedulerLimit: Int? = nil) {
        self.state = state
        self.cpuSpeedLimit = cpuSpeedLimit
        self.schedulerLimit = schedulerLimit
    }

    public static func read() -> ThermalStatus {
        var status = parse(therm: Command.output("/usr/bin/pmset", ["-g", "therm"]) ?? "")
        switch ProcessInfo.processInfo.thermalState {
        case .fair: status.state = .fair
        case .serious: status.state = .serious
        case .critical: status.state = .critical
        default: status.state = .nominal
        }
        return status
    }

    /// "CPU_Speed_Limit \t= 100" lines of `pmset -g therm`.
    static func parse(therm text: String) -> ThermalStatus {
        func value(_ key: String) -> Int? {
            for line in text.split(separator: "\n") where line.contains(key) {
                if let part = line.split(separator: "=").last, let n = Int(part.trimmingCharacters(in: .whitespaces)) { return n }
            }
            return nil
        }
        return ThermalStatus(state: .nominal, cpuSpeedLimit: value("CPU_Speed_Limit"), schedulerLimit: value("CPU_Scheduler_Limit"))
    }
}
