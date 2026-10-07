import MacSensors
import SwiftUI
import FixStatCore

/// Technician mode (2026-10 design "T2"): model card, battery and cells, every sensor grouped
/// by component with each group's hottest reading, fans.
@available(macOS 14.0, *)
struct TechnicianPanel: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(Pref.warmThreshold) private var warm = Pref.defaultWarm
    @AppStorage(Pref.hotThreshold) private var hot = Pref.defaultHot
    @AppStorage(Pref.cellImbalanceThreshold) private var imbalanceThreshold = Pref.defaultCellImbalance
    @AppStorage(Pref.hiddenSensors) private var hiddenRaw = ""
    /// Expanded sensor groups (group raw values, "unmatched").
    @State private var expanded: Set<String> = [SensorMap.Group.cpu.rawValue]

    var body: some View {
        VStack(alignment: .leading, spacing: Design.cardSpacing) {
            header
            if let battery = monitor.battery {
                batteryCard(battery)
            }
            sensorCard
            fanCard
            // Four buttons on 360 pt: small controls, so nothing truncates or widens the panel.
            HStack(spacing: 6) {
                SettingsButton()
                ToolsMenu()
                Spacer(minLength: 0)
                ExportMenu()
                QuitButton()
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .monospacedDigit()
    }

    // MARK: Header

    private var header: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: monitor.system.marketingName ?? monitor.system.model)
                    .font(.headline)
                Spacer()
                Text("Technician")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: modelLine)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            // Desktops have an internal power supply, not an adapter.
            if monitor.profile.hasBattery {
                Text(BatteryText.adapter(monitor.battery)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var modelLine: String {
        [monitor.system.model, monitor.system.boardTarget, monitor.system.chip]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: Battery and cells

    private func batteryCard(_ b: BatteryInfo) -> some View {
        Card {
            CardHeader("Battery", systemImage: "battery.75percent") {
                HStack(spacing: 8) {
                    if let cells = b.cellVoltages, !cells.isEmpty { balanceChip(cells) }
                    DetailsLink().fixedSize()
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: Design.rowSpacing) {
                GridRow {
                    CardRow(title: Text("Health"), value: b.healthPercent.map { Format.percent($0, digits: 1) })
                    CardRow(title: Text("Cycles"), value: b.cycleCount.map { Format.number(Double($0)) })
                }
                GridRow {
                    CardRow(title: Text("Max cap."), value: b.rawMaxCapacity.map(Format.milliampHours))
                    CardRow(title: Text("Design cap."), value: b.designCapacity.map(Format.milliampHours))
                }
                GridRow {
                    CardRow(title: Text("Current"), value: b.amperage.map { Format.milliamps($0) })
                    CardRow(title: Text("Voltage"), value: b.voltage.map { Format.volts(millivolts: $0) })
                }
                GridRow {
                    CardRow(title: Text("Temperature"), value: b.temperature.map { Format.temperature($0) })
                    if b.isCharging == true {
                        CardRow(title: Text("Full in"), value: b.timeToFull.map(Format.minutes))
                    } else {
                        CardRow(title: Text("Remaining"), value: (b.timeToEmpty ?? b.timeRemaining).map(Format.minutes))
                    }
                }
                if let cells = b.cellVoltages, !cells.isEmpty {
                    Color.clear.frame(height: 4).gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(stride(from: 0, to: cells.count, by: 2)), id: \.self) { index in
                        GridRow {
                            cellRow(index, cells[index])
                            if index + 1 < cells.count { cellRow(index + 1, cells[index + 1]) }
                        }
                    }
                }
            }
        }
    }

    private func cellRow(_ index: Int, _ millivolts: Int) -> some View {
        CardRow(title: Text("Cell \(index + 1)"), value: Format.volts(millivolts: millivolts, digits: 3),
                valueStyle: millivolts < CellAnalysis.minimumVoltage ? TemperatureColor.hot : nil)
    }

    private func balanceChip(_ cells: [Int]) -> some View {
        let spread = (cells.max() ?? 0) - (cells.min() ?? 0)
        let balanced = spread <= imbalanceThreshold
        let color = balanced ? TemperatureColor.cool : TemperatureColor.hot
        return Label {
            Text(balanced ? "\(Format.millivolts(spread)) · balanced" : "\(Format.millivolts(spread)) · imbalanced")
        } icon: {
            Image(systemName: balanced ? "checkmark.circle" : "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .help(Text("Spread between the highest and the lowest cell"))
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }

    // MARK: Sensors

    /// Display order and names of the sensor groups.
    static let groups: [(SensorMap.Group, LocalizedStringKey)] = [
        (.cpu, "CPU"), (.gpu, "GPU"), (.other, "PMU and board"), (.ssd, "SSD"), (.battery, "Battery"), (.chassis, "Chassis"),
    ]

    private var sensorCard: some View {
        let hidden = Pref.hiddenSet(hiddenRaw)
        // Sensors the last sensor check flagged stay visible even without a plausible value.
        let suspicious = Set(monitor.lastSensorCheck?.known.map(\.uid) ?? [])
        let shown = monitor.sensors.filter {
            !hidden.contains($0.id) && (monitor.value(of: $0) != nil || suspicious.contains($0.id))
        }
        let matched = shown.filter(\.isMatched).sorted(by: SensorOrder.displayOrder)
        let unmatched = shown.filter { !$0.isMatched }.sorted { $0.name < $1.name }
        let modelMatches = shown.filter(\.isModelMatch).count
        let sections = Self.groups.compactMap { group, title -> (String, LocalizedStringKey, [DisplaySensor])? in
            let sensors = matched.filter { $0.group == group }
            return sensors.isEmpty ? nil : (group.rawValue, title, sensors)
        } + (unmatched.isEmpty ? [] : [("unmatched", LocalizedStringKey("Unmatched"), unmatched)])
        let rows = sections.reduce(0) { $0 + 1 + (expanded.contains($1.0) ? $1.2.count : 0) }

        return Card {
            CardHeader("Sensors", systemImage: "thermometer.medium") {
                Text("\(modelMatches) / \(shown.count) matched on this model").foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sections, id: \.0) { id, title, sensors in
                        groupHeader(id: id, title: title, sensors: sensors)
                        if expanded.contains(id) {
                            ForEach(sensors) { sensor in
                                TechSensorRow(sensor: sensor, value: monitor.value(of: sensor), warm: warm, hot: hot,
                                              suspicious: suspicious.contains(sensor.id))
                            }
                        }
                    }
                }
            }
            // Explicit height, see DefaultPanel: a ScrollView in the menu bar
            // window would otherwise collapse.
            .frame(height: min(CGFloat(rows) * 27, 320))
        }
    }

    private func groupHeader(id: String, title: LocalizedStringKey, sensors: [DisplaySensor]) -> some View {
        let hottest = sensors.compactMap { monitor.value(of: $0) }.max()
        let color = TemperatureColor.color(for: hottest, warm: warm, hot: hot)
        let isOpen = expanded.contains(id)
        return Button {
            if isOpen { expanded.remove(id) } else { expanded.insert(id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                Text(title).foregroundStyle(.secondary)
                Text(verbatim: "\(sensors.count)").font(.caption).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
                if let hottest {
                    Text("hottest \(Format.degrees(hottest, digits: 1))")
                        .foregroundStyle(hottest >= warm ? color : .secondary)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? Text("expanded") : Text("collapsed"))
    }

    // MARK: Fans

    private var fanCard: some View {
        Card {
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

/// Sensor row: colour dot, name, "estimated" tag, raw key, value.
@available(macOS 14.0, *)
struct TechSensorRow: View {
    let sensor: DisplaySensor
    let value: Double?
    let warm: Double
    let hot: Double
    /// Flagged by the last sensor check.
    var suspicious = false

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: TemperatureColor.color(for: value, warm: warm, hot: hot),
                      level: value.map { $0 >= hot ? 2 : $0 >= warm ? 1 : 0 } ?? 0)
            Text(verbatim: sensor.name).lineLimit(1)
            if sensor.isMatched && sensor.isEstimated {
                Text("estimated")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(TemperatureColor.warm)
                    .background(TemperatureColor.warm.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }
            Spacer(minLength: 6)
            if suspicious {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(TemperatureColor.hot)
                    .help(Text("Suspicious sensor (hardware check)"))
            }
            Text(verbatim: sensor.descriptor.rawLabel)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value.map { Format.degrees($0, digits: 1) } ?? "–")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .padding(.leading, 18)
        .accessibilityElement(children: .combine)
    }
}
