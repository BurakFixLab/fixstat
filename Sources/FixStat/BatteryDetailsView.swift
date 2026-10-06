import MacSensors
import SwiftUI
import FixStatCore

/// Battery and charging diagnostics: cells, pack, lifetime data, charger and USB-C PD.
@available(macOS 14.0, *)
struct BatteryDetailsView: View {
    static let windowID = "battery-details"

    @Environment(Monitor.self) private var monitor
    @State private var macOSHealth: MacOSBatteryHealth?

    var body: some View {
        ScrollView {
            if let battery = monitor.battery {
                VStack(alignment: .leading, spacing: 12) {
                    OriginalitySection(battery: battery, model: monitor.system.model,
                                       reference: monitor.partsReference, macOSHealth: macOSHealth)
                    CellsSection(battery: battery)
                    HStack(alignment: .top, spacing: Design.cardSpacing) {
                        PackSection(battery: battery)
                        LifetimeSection(lifetime: battery.lifetime)
                    }
                    HStack(alignment: .top, spacing: Design.cardSpacing) {
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
        .task {
            macOSHealth = await Task.detached { MacOSBatteryHealth.read() }.value
        }
        .onAppear { monitor.detailsVisible = true }
        .onDisappear { monitor.detailsVisible = false }
    }
}

// MARK: - Building blocks

/// A titled group of label / value rows: a card with an icon in its header.
@available(macOS 14.0, *)
private struct DetailGroup<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        Card {
            CardHeader(title, systemImage: systemImage)
            content
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

@available(macOS 14.0, *)
private struct DetailRow: View {
    let title: LocalizedStringKey
    let value: String?
    var highlight = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "–")
                .monospacedDigit()
                .foregroundStyle(highlight ? TemperatureColor.hot : .primary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Originality

@available(macOS 14.0, *)
private struct OriginalitySection: View {
    let battery: BatteryInfo
    let model: String
    let reference: PartsReference
    let macOSHealth: MacOSBatteryHealth?

    var body: some View {
        let batteryCheck = PartCheck.battery(battery, model: model, reference: reference)
        let adapterCheck = PartCheck.adapter(battery, reference: reference)
        DetailGroup(title: "Originality check", systemImage: "checkmark.shield") {
            HStack(alignment: .top, spacing: 18) {
                PartCheckColumn(title: "Battery", check: batteryCheck)
                if let adapterCheck {
                    PartCheckColumn(title: "Power adapter", check: adapterCheck)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Power adapter").font(.callout.weight(.semibold))
                        Text("Connect the power adapter to check it.").font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if let condition = macOSHealth?.condition {
                Label {
                    let text = String(localized: "macOS battery condition: \(PartText.condition(condition))")
                    Text(verbatim: text + (macOSHealth?.maximumCapacity.map { " · \($0)" } ?? ""))
                } icon: {
                    Image(systemName: macOSHealth?.isGood == true ? "checkmark.circle" : "exclamationmark.triangle.fill")
                }
                .foregroundStyle(macOSHealth?.isGood == true ? TemperatureColor.cool : TemperatureColor.hot)
            }
            Text("macOS has no genuine-part flag for Mac batteries and clones can copy digital data, so this is a consistency check against known genuine parts, not proof.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

@available(macOS 14.0, *)
private struct PartCheckColumn: View {
    let title: LocalizedStringKey
    let check: PartCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout.weight(.semibold))
            Label {
                Text(verbatim: PartText.verdict(check.verdict))
            } icon: {
                Image(systemName: check.verdict == .consistent ? "checkmark.seal.fill"
                      : check.verdict == .suspicious ? "exclamationmark.triangle.fill" : "questionmark.circle")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(check.verdict == .consistent ? TemperatureColor.cool
                             : check.verdict == .suspicious ? TemperatureColor.hot : .secondary)
            ForEach(Array(check.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: item.status == .pass ? "checkmark" : item.status == .warn ? "exclamationmark.triangle" : "info.circle")
                        .foregroundStyle(item.status == .pass ? TemperatureColor.cool : item.status == .warn ? TemperatureColor.hot : .secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: PartText.item(item.id)).fixedSize(horizontal: false, vertical: true)
                        if !item.detail.isEmpty {
                            Text(verbatim: item.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Cells

@available(macOS 14.0, *)
private struct CellsSection: View {
    let battery: BatteryInfo

    var body: some View {
        let analysis = CellAnalysis(battery: battery)
        DetailGroup(title: "Cells", systemImage: "square.stack.3d.up") {
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
                            .foregroundStyle(cell.lowVoltage ? TemperatureColor.hot : .primary)
                        Text(cell.qmax.map(Format.milliampHours) ?? "–")
                            .foregroundStyle(cell.lowCapacity ? TemperatureColor.hot : .primary)
                        Text(cell.resistance.map { Format.number(Double($0)) } ?? "–")
                            .foregroundStyle(cell.highResistance ? TemperatureColor.hot : .primary)
                        Text(BatteryDetailText.deviation(cell))
                            .foregroundStyle(cell.isSuspect ? TemperatureColor.hot : .secondary)
                    }
                    .monospacedDigit()
                }
            }
            .padding(.bottom, 4)
            if analysis.suspects.isEmpty, !analysis.defaultQmax {
                Label("Cells are consistent.", systemImage: "checkmark.circle")
                    .foregroundStyle(TemperatureColor.cool)
            }
            if analysis.defaultQmax {
                Label(BatteryDetailText.defaultQmax, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            if !analysis.suspects.isEmpty {
                ForEach(analysis.suspects, id: \.number) { cell in
                    Label {
                        Text(BatteryDetailText.finding(cell))
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

}

// MARK: - Pack

@available(macOS 14.0, *)
private struct PackSection: View {
    let battery: BatteryInfo

    var body: some View {
        DetailGroup(title: "Pack", systemImage: "battery.100percent") {
            DetailRow(title: "Gauge", value: battery.gaugeDeviceName)
            DetailRow(title: "Chemistry ID", value: battery.identity?.chemistryID.map { String($0) })
            DetailRow(title: "Manufacturer data", value: BatteryDetailText.manufacturer(battery))
            DetailRow(title: "Cycles", value: BatteryDetailText.cycles(battery))
            DetailRow(title: "Health", value: battery.healthPercent.map { Format.percent($0, digits: 1) })
            DetailRow(title: "Nominal health", value: battery.nominalHealthPercent.map { Format.percent($0, digits: 1) })
            DetailRow(title: "Permanent failure", value: BatteryDetailText.hex(battery.permanentFailureStatus),
                      highlight: (battery.permanentFailureStatus ?? 0) != 0)
            DetailRow(title: "Cell disconnects", value: battery.cellDisconnectCount.map { Format.number(Double($0)) },
                      highlight: (battery.cellDisconnectCount ?? 0) != 0)
            DetailRow(title: "Flash writes", value: battery.identity?.dataFlashWriteCount.map { Format.number(Double($0)) })
            DetailRow(title: "Serial", value: battery.serial)
        }
    }

}

// MARK: - Lifetime

@available(macOS 14.0, *)
private struct LifetimeSection: View {
    let lifetime: BatteryLifetime?

    var body: some View {
        DetailGroup(title: "Lifetime (gauge)", systemImage: "clock.arrow.circlepath") {
            DetailRow(title: "Operating time", value: lifetime?.totalOperatingTime.map(BatteryDetailText.hours))
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

@available(macOS 14.0, *)
private struct ChargingSection: View {
    let battery: BatteryInfo

    var body: some View {
        let charger = battery.charger
        let telemetry = battery.powerTelemetry
        DetailGroup(title: "Charger", systemImage: "bolt") {
            DetailRow(title: "State", value: BatteryText.state(battery))
            DetailRow(title: "Battery current", value: battery.amperage.map { Format.milliamps($0) })
            DetailRow(title: "Charger target current", value: charger?.chargingCurrent.map { Format.milliamps($0, signed: false) })
            DetailRow(title: "Charger target voltage", value: charger?.chargingVoltage.map { Format.volts(millivolts: $0, digits: 3) })
            DetailRow(title: "Input", value: BatteryDetailText.input(telemetry))
            DetailRow(title: "Not charging reason", value: BatteryDetailText.notCharging(charger?.notChargingReason))
            DetailRow(title: "Slow charging reason", value: BatteryDetailText.hex(charger?.slowChargingReason),
                      highlight: (charger?.slowChargingReason ?? 0) != 0)
            DetailRow(title: "Charger inhibit reason", value: BatteryDetailText.hex(charger?.chargerInhibitReason),
                      highlight: (charger?.chargerInhibitReason ?? 0) != 0)
            DetailRow(title: "Thermally limited", value: charger?.timeChargingThermallyLimited.map { Format.number(Double($0)) },
                      highlight: (charger?.timeChargingThermallyLimited ?? 0) != 0)
            Text("Reason codes are Apple's undocumented bit fields, shown as reported. 0 means none.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

// MARK: - USB-C Power Delivery

@available(macOS 14.0, *)
private struct PowerDeliverySection: View {
    let battery: BatteryInfo

    var body: some View {
        let pd = battery.powerDelivery
        let connected = battery.externalConnected == true
        DetailGroup(title: "USB-C Power Delivery", systemImage: "cable.connector") {
            if let pd, let active = pd.activeProfile ?? pd.contract?.sourceObject {
                if !connected {
                    Text("No power adapter — last contract:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DetailRow(title: "Contract", value: BatteryDetailText.profile(active, position: pd.activePosition))
                if let contract = pd.consistentContract {
                    DetailRow(title: "Requested", value: BatteryDetailText.requested(contract))
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
                            Text(verbatim: BatteryDetailText.pdo(pdo))
                            Spacer()
                            if index + 1 == pd.activePosition {
                                Text("in use").font(.caption).foregroundStyle(TemperatureColor.cool)
                            }
                        }
                        .font(.callout.monospaced())
                    }
                }
                .font(.callout)
                DetailRow(title: "Plug-ins / removals", value: BatteryDetailText.counts(pd))
                DetailRow(title: "Hard resets", value: pd.hardResetCount.map { Format.number(Double($0)) })
            } else {
                Text("No USB-C Power Delivery contract.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
