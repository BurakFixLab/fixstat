import SwiftUI

/// Status item content: battery icon, percentage and CPU temperature, each optional.
struct MenuBarLabel: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.menuBarBatteryIcon) private var showIcon = true
    @AppStorage(Pref.menuBarBatteryPercent) private var showPercent = true
    @AppStorage(Pref.menuBarCPUTemperature) private var showTemperature = true

    var body: some View {
        let parts = textParts
        HStack(spacing: 4) {
            if showIcon, monitor.battery != nil {
                Image(systemName: BatteryText.symbol(monitor.battery))
            }
            if !parts.isEmpty {
                Text(parts.joined(separator: " · ")).monospacedDigit()
            } else if !showIcon || monitor.battery == nil {
                Image(systemName: "thermometer.medium")
            }
        }
        .accessibilityLabel(Text("FixStat"))
    }

    private var textParts: [String] {
        var parts: [String] = []
        if showPercent, let soc = monitor.battery?.stateOfCharge {
            parts.append(Format.percent(soc))
        }
        if showTemperature, let cpu = monitor.cpuTemperature {
            parts.append(Format.degrees(cpu))
        }
        return parts
    }
}
