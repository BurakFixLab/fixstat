import MacSensors
import SwiftUI

/// Design A: battery, the most important sensors, fans and system load.
struct DefaultPanel: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.warmThreshold) private var warm = Pref.defaultWarm
    @AppStorage(Pref.hotThreshold) private var hot = Pref.defaultHot
    @AppStorage(Pref.hiddenSensors) private var hiddenRaw = ""
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let battery = monitor.battery {
                batterySection(battery)
                Divider()
            }
            sensorSection
            Divider()
            HStack(alignment: .top, spacing: 16) {
                fanColumn
                systemColumn
            }
            Divider()
            HStack {
                SettingsButton()
                Spacer()
                QuitButton()
            }
        }
    }

    // MARK: Battery

    private func batterySection(_ battery: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(title: "Battery")
                Spacer()
                Text(BatteryText.state(battery)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(battery.stateOfCharge.map { Format.percent($0) } ?? "–")
                    .font(.system(size: 34, weight: .semibold))
                    .monospacedDigit()
                if let time = BatteryText.time(battery) {
                    Text(time).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            LevelBar(fraction: (battery.stateOfCharge ?? 0) / 100, color: .accentColor, height: 5)
            HStack(spacing: 8) {
                Tile(title: "Health", value: battery.healthPercent.map { Format.percent($0) } ?? "–")
                Tile(title: "Cycles", value: battery.cycleCount.map { Format.number(Double($0)) } ?? "–")
                Tile(title: "Temperature", value: battery.temperature.map { Format.degrees($0) } ?? "–")
            }
        }
    }

    // MARK: Sensors

    /// Aggregated rows shown by default: the hottest sensor of each kind.
    private static let summaries: [(title: LocalizedStringKey, prefixes: [String])] = [
        ("Performance clusters", ["cpu.pcluster"]),
        ("Efficiency clusters", ["cpu.ecluster"]),
        ("CPU", ["cpu.core", "cpu.die", "cpu.proximity"]),
        ("GPU", ["gpu."]),
        ("SSD (NAND)", ["ssd.nand", "ssd."]),
        ("Enclosure", ["chassis.skin", "chassis.palmrest"]),
        ("Battery", ["battery."]),
    ]

    private var sensorSection: some View {
        let hidden = Pref.hiddenSet(hiddenRaw)
        let visible = monitor.sensors.filter { !hidden.contains($0.id) && monitor.value(of: $0) != nil }
        let rows = Self.summaries.compactMap { summary -> (LocalizedStringKey, Double)? in
            monitor.maximum(idPrefixes: summary.prefixes, excluding: hidden).map { (summary.title, $0) }
        }.prefix(6)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Sensors")
                Spacer()
                Button(showAll ? "Less" : "All (\(visible.count))") { showAll.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if showAll {
                // Explicit height: inside the menu bar window a ScrollView has no
                // ideal height of its own and would collapse to zero.
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(visible.sorted(by: Self.displayOrder)) { sensor in
                            sensorRow(Text(sensor.name), monitor.value(of: sensor))
                        }
                    }
                }
                .frame(height: min(CGFloat(visible.count) * Self.rowHeight, 280))
            } else if rows.isEmpty {
                Text("No temperature sensors found").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    sensorRow(Text(row.0), row.1)
                }
            }
        }
    }

    /// Id prefixes in display order; unlisted ids come after, by group.
    private static let idOrder = ["cpu.pcluster", "cpu.ecluster", "cpu.", "gpu.", "ssd.nand", "ssd.",
                                  "battery.", "chassis.", "soc.", "board.", "pmu.", "pmu2."]

    /// Approximate height of one sensor row including spacing.
    static let rowHeight: CGFloat = 22

    static func displayOrder(_ a: DisplaySensor, _ b: DisplaySensor) -> Bool {
        func rank(_ sensor: DisplaySensor) -> Int {
            guard let id = sensor.resolved?.id else { return idOrder.count + 1 }
            return idOrder.firstIndex { id.hasPrefix($0) } ?? idOrder.count
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        let ka = a.resolved?.id ?? a.name
        let kb = b.resolved?.id ?? b.name
        return ka.localizedStandardCompare(kb) == .orderedAscending
    }

    private func sensorRow(_ title: Text, _ value: Double?) -> some View {
        let color = TemperatureColor.color(for: value, warm: warm, hot: hot)
        return HStack(spacing: 10) {
            title.font(.callout).lineLimit(1)
            Spacer(minLength: 8)
            LevelBar(fraction: value?.temperatureFraction ?? 0, color: color)
                .frame(width: 56)
            Text(value.map { Format.degrees($0) } ?? "–")
                .font(.callout)
                .monospacedDigit()
                .frame(width: 40, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Fans & system

    private var fanColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Fans")
            if monitor.fans.isEmpty {
                Text("No fans").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.fans, id: \.index) { fan in
                    ValueRow(title: Text("Fan \(fan.index + 1)"), value: fan.actual.map(Format.rpm))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var systemColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "System")
            ValueRow(title: Text("CPU"), value: monitor.cpuUsage.map { Format.percent($0 * 100) })
            ValueRow(title: Text("Memory"), value: monitor.memory.map { memory in
                String(localized: "\(Format.number(Double(memory.used) / 1_073_741_824, digits: 1)) / \(Format.gigabytes(memory.total, digits: 0))",
                       comment: "Memory used / total")
            })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label on the left, value right-aligned.
private struct ValueRow: View {
    let title: Text
    let value: String?

    var body: some View {
        HStack {
            title
            Spacer(minLength: 8)
            Text(value ?? "–").monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
