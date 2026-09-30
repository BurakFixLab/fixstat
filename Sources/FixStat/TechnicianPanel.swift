import MacSensors
import SwiftUI
import FixStatCore

/// Design B: raw battery data, cell voltages, every sensor with its raw key.
@available(macOS 14.0, *)
struct TechnicianPanel: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.warmThreshold) private var warm = Pref.defaultWarm
    @AppStorage(Pref.hotThreshold) private var hot = Pref.defaultHot
    @AppStorage(Pref.cellImbalanceThreshold) private var imbalanceThreshold = Pref.defaultCellImbalance
    @AppStorage(Pref.hiddenSensors) private var hiddenRaw = ""
    @State private var showUnmatched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let battery = monitor.battery {
                batteryGrid(battery)
                if let cells = battery.cellVoltages, !cells.isEmpty {
                    cellSection(cells)
                }
            }
            sensorSection
            fanRow
            // Four buttons on 360 pt: small controls, so nothing truncates or widens the panel.
            HStack(spacing: 6) {
                SettingsButton()
                ToolsMenu()
                Spacer(minLength: 0)
                ExportMenu()
                QuitButton()
            }
            .controlSize(.small)
        }
        .monospacedDigit()
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: monitor.system.marketingName ?? monitor.system.model)
                    .font(.headline)
                Text(verbatim: modelLine)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(BatteryText.adapter(monitor.battery)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Technician")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var modelLine: String {
        [monitor.system.model, monitor.system.boardTarget, monitor.system.chip]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: Battery

    private func batteryGrid(_ b: BatteryInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Battery")
                Spacer()
                DetailsLink()
            }
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    TechCell(title: "Design cap.", value: b.designCapacity.map(Format.milliampHours))
                    TechCell(title: "Max cap.", value: b.rawMaxCapacity.map(Format.milliampHours))
                }
                GridRow {
                    TechCell(title: "Health", value: b.healthPercent.map { Format.percent($0, digits: 1) })
                    TechCell(title: "Cycles", value: b.cycleCount.map { Format.number(Double($0)) })
                }
                GridRow {
                    TechCell(title: "Current", value: b.amperage.map { Format.milliamps($0) })
                    TechCell(title: "Voltage", value: b.voltage.map { Format.volts(millivolts: $0) })
                }
                GridRow {
                    TechCell(title: "Temperature", value: b.temperature.map { Format.temperature($0) })
                    if b.isCharging == true {
                        TechCell(title: "Full in", value: b.timeToFull.map(Format.minutes))
                    } else {
                        TechCell(title: "Remaining", value: (b.timeToEmpty ?? b.timeRemaining).map(Format.minutes))
                    }
                }
            }
        }
    }

    private func cellSection(_ cells: [Int]) -> some View {
        let spread = (cells.max() ?? 0) - (cells.min() ?? 0)
        let balanced = spread <= imbalanceThreshold
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionTitle(title: "Cell voltages")
                Spacer()
                Label {
                    Text(balanced
                         ? "Spread \(Format.millivolts(spread)) · balanced"
                         : "Spread \(Format.millivolts(spread)) · imbalanced")
                } icon: {
                    Image(systemName: balanced ? "checkmark.circle" : "exclamationmark.triangle.fill")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .foregroundStyle(balanced ? TemperatureColor.cool : TemperatureColor.hot)
                .background((balanced ? TemperatureColor.cool : TemperatureColor.hot).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 4))
            }
            ForEach(Array(cells.enumerated()), id: \.offset) { index, millivolts in
                HStack(spacing: 10) {
                    Text("Cell \(index + 1)").font(.callout).frame(width: 64, alignment: .leading)
                    // Scale 3.0 V … 4.35 V
                    LevelBar(fraction: (Double(millivolts) - 3000) / 1350, color: TemperatureColor.cool)
                    Text(Format.volts(millivolts: millivolts, digits: 3))
                        .font(.callout.monospaced())
                        .frame(width: 72, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Sensors

    private var sensorSection: some View {
        let hidden = Pref.hiddenSet(hiddenRaw)
        let shown = monitor.sensors.filter { !hidden.contains($0.id) && monitor.value(of: $0) != nil }
        let matched = shown.filter(\.isMatched).sorted(by: SensorOrder.displayOrder)
        let unmatched = shown.filter { !$0.isMatched }.sorted { $0.name < $1.name }
        let modelMatches = shown.filter(\.isModelMatch).count

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(title: "Sensors")
                Spacer()
                Text("\(modelMatches) / \(shown.count) matched on this model")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(matched) { sensor in
                        TechSensorRow(sensor: sensor, value: monitor.value(of: sensor), warm: warm, hot: hot)
                        Divider()
                    }
                    if !unmatched.isEmpty {
                        DisclosureGroup(isExpanded: $showUnmatched) {
                            ForEach(unmatched) { sensor in
                                TechSensorRow(sensor: sensor, value: monitor.value(of: sensor), warm: warm, hot: hot)
                            }
                        } label: {
                            Text("Unmatched sensors (\(unmatched.count))").font(.callout)
                        }
                        .padding(.top, 6)
                    }
                }
            }
            // Explicit height, see DefaultPanel: a ScrollView in the menu bar
            // window would otherwise collapse.
            .frame(height: min(CGFloat(matched.count + (unmatched.isEmpty ? 0 : 1)) * 29, 300))
        }
    }

    private var fanRow: some View {
        HStack {
            if monitor.fans.isEmpty {
                Text("No fans").foregroundStyle(.secondary)
            } else {
                ForEach(monitor.fans, id: \.index) { fan in
                    Text("Fan \(fan.index + 1)").foregroundStyle(.secondary)
                    Text(fan.actual.map(Format.rpm) ?? "–").font(.callout.monospaced())
                    if fan.index < monitor.fans.count - 1 { Spacer() }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Label / value cell of the battery grid.
@available(macOS 14.0, *)
private struct TechCell: View {
    let title: LocalizedStringKey
    let value: String?

    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value ?? "–").font(.callout.monospaced()).lineLimit(1)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// Sensor row: colour dot, name, "estimated" tag, raw key, value.
@available(macOS 14.0, *)
struct TechSensorRow: View {
    let sensor: DisplaySensor
    let value: Double?
    let warm: Double
    let hot: Double

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(TemperatureColor.color(for: value, warm: warm, hot: hot))
                .frame(width: 7, height: 7)
            Text(verbatim: sensor.name).font(.callout).lineLimit(1)
            if sensor.isMatched && sensor.isEstimated {
                Text("estimated")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(TemperatureColor.warm)
                    .background(TemperatureColor.warm.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 6)
            Text(verbatim: sensor.descriptor.rawLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value.map { Format.degrees($0, digits: 1) } ?? "–")
                .font(.callout.monospaced())
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
