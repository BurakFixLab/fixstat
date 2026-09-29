import MacSensors
import SwiftUI

/// Battery and charging diagnostics: cells, pack, lifetime data, charger and USB-C PD.
struct BatteryDetailsView: View {
    static let windowID = "battery-details"

    @Environment(Monitor.self) private var monitor

    var body: some View {
        ScrollView {
            if let battery = monitor.battery {
                VStack(alignment: .leading, spacing: 18) {
                    CellsSection(battery: battery)
                    HStack(alignment: .top, spacing: 18) {
                        PackSection(battery: battery)
                        LifetimeSection(lifetime: battery.lifetime)
                    }
                    HStack(alignment: .top, spacing: 18) {
                        ChargingSection(battery: battery)
                        PowerDeliverySection(battery: battery)
                    }
                }
                .padding(20)
            } else {
                ContentUnavailableView("No battery", systemImage: "battery.0percent",
                                       description: Text("This Mac has no internal battery."))
                    .padding(40)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
        .monospacedDigit()
        .onAppear { monitor.detailsVisible = true }
        .onDisappear { monitor.detailsVisible = false }
    }
}

// MARK: - Building blocks

/// A titled group of label / value rows.
private struct DetailGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: title)
            VStack(alignment: .leading, spacing: 5) { content }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct DetailRow: View {
    let title: LocalizedStringKey
    let value: String?
    var highlight = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "–")
                .font(.callout.monospaced())
                .foregroundStyle(highlight ? TemperatureColor.hot : .primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

private func hex(_ value: Int?) -> String? {
    value.map { $0 == 0 ? "0" : String(format: "0x%X", $0) }
}

private func signedPercent(_ fraction: Double) -> String {
    (fraction * 100).formatted(.number.precision(.fractionLength(0)).sign(strategy: .always(includingZero: false)))
        .appending(" %")
}

// MARK: - Cells

private struct CellsSection: View {
    let battery: BatteryInfo

    var body: some View {
        let analysis = CellAnalysis(battery: battery)
        DetailGroup(title: "Cells") {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Cell").gridColumnAlignment(.leading)
                    Text("Voltage")
                    Text("Qmax")
                    Text("Resistance")
                    Text("vs. average")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(analysis.cells, id: \.number) { cell in
                    GridRow {
                        Text("Cell \(cell.number)").gridColumnAlignment(.leading)
                        Text(cell.voltage.map { Format.volts(millivolts: $0, digits: 3) } ?? "–")
                        Text(cell.qmax.map(Format.milliampHours) ?? "–")
                            .foregroundStyle(cell.lowCapacity ? TemperatureColor.hot : .primary)
                        Text(cell.resistance.map { Format.number(Double($0)) } ?? "–")
                            .foregroundStyle(cell.highResistance ? TemperatureColor.hot : .primary)
                        Text(deviationText(cell))
                            .foregroundStyle(cell.isSuspect ? TemperatureColor.hot : .secondary)
                    }
                    .font(.callout.monospaced())
                }
            }
            Divider().padding(.vertical, 2)
            if analysis.suspects.isEmpty {
                Label("Cells are consistent.", systemImage: "checkmark.circle")
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                ForEach(analysis.suspects, id: \.number) { cell in
                    Label {
                        Text(finding(cell))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(TemperatureColor.hot)
                }
            }
            Text("Resistance is the gauge's weighted cell resistance; its unit is not documented, compare the cells with each other.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func deviationText(_ cell: CellAnalysis.Cell) -> String {
        [cell.resistanceDeviation.map { "R " + signedPercent($0) },
         cell.qmaxDeviation.map { "Q " + signedPercent($0) }]
            .compactMap { $0 }
            .joined(separator: "  ")
    }

    private func finding(_ cell: CellAnalysis.Cell) -> String {
        var parts: [String] = []
        if cell.highResistance, let dev = cell.resistanceDeviation {
            parts.append(String(localized: "resistance \(signedPercent(dev)) vs. average"))
        }
        if cell.lowCapacity, let dev = cell.qmaxDeviation {
            parts.append(String(localized: "Qmax \(signedPercent(dev)) vs. average"))
        }
        return String(localized: "Cell \(cell.number): \(parts.joined(separator: ", "))")
    }
}

// MARK: - Pack

private struct PackSection: View {
    let battery: BatteryInfo

    var body: some View {
        DetailGroup(title: "Pack") {
            DetailRow(title: "Gauge", value: battery.gaugeDeviceName)
            DetailRow(title: "Chemistry ID", value: battery.identity?.chemistryID.map { String($0) })
            DetailRow(title: "Manufacturer data", value: manufacturer)
            DetailRow(title: "Cycles", value: cycles)
            DetailRow(title: "Health", value: battery.healthPercent.map { Format.percent($0, digits: 1) })
            DetailRow(title: "Nominal health", value: battery.nominalHealthPercent.map { Format.percent($0, digits: 1) })
            DetailRow(title: "Permanent failure", value: hex(battery.permanentFailureStatus),
                      highlight: (battery.permanentFailureStatus ?? 0) != 0)
            DetailRow(title: "Cell disconnects", value: battery.cellDisconnectCount.map { Format.number(Double($0)) },
                      highlight: (battery.cellDisconnectCount ?? 0) != 0)
            DetailRow(title: "Flash writes", value: battery.identity?.dataFlashWriteCount.map { Format.number(Double($0)) })
            DetailRow(title: "Serial", value: battery.serial)
        }
    }

    private var manufacturer: String? {
        guard let strings = battery.identity?.manufacturerStrings, !strings.isEmpty else { return nil }
        return strings.joined(separator: " · ")
    }

    private var cycles: String? {
        guard let count = battery.cycleCount else { return nil }
        guard let design = battery.designCycleCount else { return Format.number(Double(count)) }
        return String(localized: "\(Format.number(Double(count))) of \(Format.number(Double(design)))")
    }
}

// MARK: - Lifetime

private struct LifetimeSection: View {
    let lifetime: BatteryLifetime?

    var body: some View {
        DetailGroup(title: "Lifetime (gauge)") {
            DetailRow(title: "Operating time", value: lifetime?.totalOperatingTime.map {
                String(localized: "\(Format.number(Double($0))) h", comment: "Hours as reported by the gauge")
            })
            DetailRow(title: "Highest temperature", value: lifetime?.maximumTemperature.map { Format.temperature($0) })
            DetailRow(title: "Average temperature", value: lifetime?.averageTemperature.map { Format.temperature($0) })
            DetailRow(title: "Lowest temperature", value: lifetime?.minimumTemperature.map { Format.temperature($0) })
            DetailRow(title: "Highest charge current", value: lifetime?.maximumChargeCurrent.map { Format.milliamps($0) })
            DetailRow(title: "Highest discharge current", value: lifetime?.maximumDischargeCurrent.map { Format.milliamps($0) })
            DetailRow(title: "Highest pack voltage", value: lifetime?.maximumPackVoltage.map { Format.volts(millivolts: $0) })
            DetailRow(title: "Lowest pack voltage", value: lifetime?.minimumPackVoltage.map { Format.volts(millivolts: $0) })
        }
    }
}

// MARK: - Charging

private struct ChargingSection: View {
    let battery: BatteryInfo

    var body: some View {
        let charger = battery.charger
        let telemetry = battery.powerTelemetry
        DetailGroup(title: "Charger") {
            DetailRow(title: "State", value: BatteryText.state(battery))
            DetailRow(title: "Battery current", value: battery.amperage.map { Format.milliamps($0) })
            DetailRow(title: "Charger target current", value: charger?.chargingCurrent.map { Format.milliamps($0, signed: false) })
            DetailRow(title: "Charger target voltage", value: charger?.chargingVoltage.map { Format.volts(millivolts: $0, digits: 3) })
            DetailRow(title: "Input", value: input(telemetry))
            DetailRow(title: "Not charging reason", value: notCharging(charger?.notChargingReason))
            DetailRow(title: "Slow charging reason", value: hex(charger?.slowChargingReason),
                      highlight: (charger?.slowChargingReason ?? 0) != 0)
            DetailRow(title: "Charger inhibit reason", value: hex(charger?.chargerInhibitReason),
                      highlight: (charger?.chargerInhibitReason ?? 0) != 0)
            DetailRow(title: "Thermally limited", value: charger?.timeChargingThermallyLimited.map { Format.number(Double($0)) },
                      highlight: (charger?.timeChargingThermallyLimited ?? 0) != 0)
            Text("Reason codes are Apple's undocumented bit fields, shown as reported. 0 means none.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func input(_ telemetry: PowerTelemetry?) -> String? {
        guard let power = telemetry?.systemPowerIn, power > 0 else { return nil }
        var parts = [Format.watts(Double(power) / 1000, digits: 1)]
        if let v = telemetry?.systemVoltageIn { parts.append(Format.volts(millivolts: v)) }
        if let i = telemetry?.systemCurrentIn { parts.append(Format.milliamps(i, signed: false)) }
        return parts.joined(separator: " · ")
    }

    private func notCharging(_ value: Int?) -> String? {
        guard let value else { return nil }
        return value == 0 ? String(localized: "none") : hex(value)
    }
}

// MARK: - USB-C Power Delivery

private struct PowerDeliverySection: View {
    let battery: BatteryInfo

    var body: some View {
        let pd = battery.powerDelivery
        let connected = battery.externalConnected == true
        DetailGroup(title: "USB-C Power Delivery") {
            if let pd, let active = pd.activeProfile ?? pd.contract?.sourceObject {
                if !connected {
                    Text("No power adapter — last contract:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DetailRow(title: "Contract", value: profileText(active, position: pd.activePosition))
                if let contract = pd.consistentContract {
                    DetailRow(title: "Requested", value: requested(contract))
                    if contract.capabilityMismatch {
                        Label("The Mac reported that the adapter cannot supply what it needs.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(TemperatureColor.hot)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Adapter offers").foregroundStyle(.secondary)
                    ForEach(Array(pd.offeredProfiles.enumerated()), id: \.offset) { index, pdo in
                        HStack {
                            Text(verbatim: "\(index + 1).")
                                .foregroundStyle(.secondary)
                            Text(verbatim: pdoText(pdo))
                            Spacer()
                            if index + 1 == pd.activePosition {
                                Text("in use").font(.caption).foregroundStyle(TemperatureColor.cool)
                            }
                        }
                        .font(.callout.monospaced())
                    }
                }
                .font(.callout)
                DetailRow(title: "Plug-ins / removals", value: counts(pd))
                DetailRow(title: "Hard resets", value: pd.hardResetCount.map { Format.number(Double($0)) })
            } else {
                Text("No USB-C Power Delivery contract.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pdoText(_ pdo: PowerDataObject) -> String {
        switch pdo.kind {
        case .fixed:
            return [pdo.maxVoltage.map { Format.volts(millivolts: $0, digits: 0) },
                    pdo.maxCurrent.map { Format.amps(milliamps: $0) }].compactMap { $0 }.joined(separator: " · ")
        case .pps, .variable:
            let range = [pdo.minVoltage, pdo.maxVoltage].compactMap { $0 }
                .map { Format.volts(millivolts: $0, digits: 1) }.joined(separator: "–")
            let kind = pdo.kind == .pps ? "PPS " : ""
            return kind + [range, pdo.maxCurrent.map { Format.amps(milliamps: $0) }].compactMap { $0 }.joined(separator: " · ")
        case .battery:
            return [pdo.minVoltage, pdo.maxVoltage].compactMap { $0 }
                .map { Format.volts(millivolts: $0, digits: 1) }.joined(separator: "–")
                + (pdo.maxPower.map { " · " + Format.watts(Double($0) / 1000) } ?? "")
        case .unknown:
            return String(format: "0x%08X", pdo.raw)
        }
    }

    private func profileText(_ pdo: PowerDataObject, position: Int?) -> String {
        var parts: [String] = []
        if let v = pdo.maxVoltage { parts.append(Format.volts(millivolts: v, digits: v % 1000 == 0 ? 0 : 1)) }
        if let i = pdo.maxCurrent { parts.append(Format.amps(milliamps: i)) }
        if let power = pdo.power { parts.append(Format.watts(Double(power) / 1000)) }
        if let position { parts.append(String(localized: "profile \(position)")) }
        return parts.joined(separator: " · ")
    }

    private func requested(_ contract: PowerDeliveryContract) -> String? {
        guard let current = contract.operatingCurrent else { return nil }
        var text = Format.amps(milliamps: current)
        if let power = contract.power { text += " · " + Format.watts(Double(power) / 1000) }
        return text
    }

    private func counts(_ pd: PowerDeliveryInfo) -> String? {
        guard let attach = pd.attachCount else { return nil }
        let detach = pd.detachCount.map { Format.number(Double($0)) } ?? "–"
        return "\(Format.number(Double(attach))) / \(detach)"
    }
}
