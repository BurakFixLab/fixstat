import MacSensors
import SwiftUI
import FixStatCore

/// Cards: battery, temperatures, fans and system load (2026-10 design "B").
@available(macOS 14.0, *)
struct DefaultPanel: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.warmThreshold) private var warm = Pref.defaultWarm
    @AppStorage(Pref.hotThreshold) private var hot = Pref.defaultHot
    @AppStorage(Pref.hiddenSensors) private var hiddenRaw = ""
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: Design.cardSpacing) {
            if let battery = monitor.battery {
                batteryCard(battery)
            }
            sensorCard
            systemCard
            HStack {
                SettingsButton()
                ToolsMenu()
                Spacer()
                QuitButton()
            }
            .padding(.top, 4)
        }
    }

    // MARK: Battery

    private func batteryCard(_ battery: BatteryInfo) -> some View {
        Card {
            CardHeader("Battery", systemImage: "battery.75percent") {
                Text(BatteryText.state(battery)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(battery.stateOfCharge.map { Format.percent($0) } ?? "–")
                    .font(.largeTitle.weight(.medium))
                    .monospacedDigit()
                if let time = BatteryText.time(battery) {
                    Text(time).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            HStack(alignment: .top, spacing: 8) {
                stat("Health", battery.healthPercent.map { Format.percent($0) })
                stat("Cycles", battery.cycleCount.map { Format.number(Double($0)) })
                stat("Temperature", battery.temperature.map { Format.degrees($0) })
            }
            .padding(.top, 2)
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "–").monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Sensors

    private var sensorCard: some View {
        let hidden = Pref.hiddenSet(hiddenRaw)
        let visible = monitor.sensors.filter { !hidden.contains($0.id) && monitor.value(of: $0) != nil }
        let rows = SensorSummary.rows(sensors: monitor.sensors, values: monitor.values, hidden: hidden)

        return Card {
            CardHeader("Temperatures", systemImage: "thermometer.medium") {
                Button(showAll ? "Less" : "All (\(visible.count))") { showAll.toggle() }
                    .buttonStyle(.link)
            }
            if showAll {
                // Explicit height: inside the menu bar window a ScrollView has no
                // ideal height of its own and would collapse to zero.
                ScrollView {
                    VStack(spacing: Design.rowSpacing) {
                        ForEach(visible.sorted(by: SensorOrder.displayOrder)) { sensor in
                            sensorRow(Text(sensor.name), monitor.value(of: sensor))
                        }
                    }
                }
                .frame(height: min(CGFloat(visible.count) * Self.rowHeight, 280))
            } else if rows.isEmpty {
                Text("No temperature sensors found").foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    sensorRow(Text(verbatim: row.title), row.value)
                }
            }
        }
    }

    /// Approximate height of one sensor row including spacing.
    static let rowHeight: CGFloat = 21

    private func sensorRow(_ title: Text, _ value: Double?) -> some View {
        let color = TemperatureColor.color(for: value, warm: warm, hot: hot)
        let level = value.map { $0 >= hot ? 2 : $0 >= warm ? 1 : 0 } ?? 0
        return HStack(spacing: 6) {
            StatusDot(color: color, level: level)
            title.lineLimit(1)
            Spacer(minLength: 8)
            Text(value.map { Format.degrees($0) } ?? "–")
                .monospacedDigit()
                .foregroundStyle(level > 0 ? color : .primary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Fans & system

    private var systemCard: some View {
        Card {
            CardHeader("System", systemImage: "cpu")
            CardRow(title: Text("CPU"), value: monitor.cpuUsage.map { Format.percent($0 * 100) })
            CardRow(title: Text("Memory"), value: monitor.memory.map { memory in
                String(localized: "\(Format.number(Double(memory.used) / 1_073_741_824, digits: 1)) / \(Format.gigabytes(memory.total, digits: 0))",
                       comment: "Memory used / total")
            })
            if monitor.fans.isEmpty {
                CardRow(title: Text("Fans"), value: String(localized: "No fans"))
            } else {
                ForEach(monitor.fans, id: \.index) { fan in
                    CardRow(title: Text("Fan \(fan.index + 1)"), value: fan.actual.map(Format.rpm))
                }
            }
        }
    }
}
