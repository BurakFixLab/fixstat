import AppKit
import MacSensors
import SwiftUI

/// Kernel panics and previous shutdown causes.
struct CrashHistoryView: View {
    static let windowID = "crash-history"

    @Environment(Monitor.self) private var monitor
    @State private var panics: [PanicReport] = []
    @State private var shutdowns: [ShutdownEvent] = []
    @State private var loadingShutdowns = true
    @State private var expanded: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                shutdownSection
                panicSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, minHeight: 520)
        .task { await load() }
    }

    private func load() async {
        // Reuse a recent scan: searching 30 days of the system log takes about a minute.
        if let scan = monitor.lastCrashScan, Date().timeIntervalSince(scan.date) < 600 {
            panics = scan.panics
            shutdowns = scan.shutdowns
            loadingShutdowns = false
            return
        }
        panics = CrashHistory.panics()
        loadingShutdowns = true
        shutdowns = await Task.detached(priority: .userInitiated) { CrashHistory.shutdownEvents(days: 30) }.value
        loadingShutdowns = false
        monitor.lastCrashScan = CrashScan(panics: panics, shutdowns: shutdowns)
    }

    private var shutdownSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Previous shutdown causes (last 30 days)")
            if loadingShutdowns {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching the system log — this can take about a minute.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if shutdowns.isEmpty {
                Text("No shutdown causes in the system log. macOS records one at every start; older entries are removed after a while.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(shutdowns) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: event.isFault ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(event.isFault ? TemperatureColor.hot : TemperatureColor.cool)
                        Text(event.date.formatted(date: .abbreviated, time: .shortened))
                            .monospacedDigit()
                            .frame(width: 150, alignment: .leading)
                        Text(verbatim: String(event.code))
                            .font(.callout.monospaced())
                            .frame(width: 44, alignment: .trailing)
                        Text(verbatim: CrashText.shutdownMeaning(event.meaning))
                            .foregroundStyle(event.meaning == nil ? .secondary : .primary)
                    }
                    .font(.callout)
                }
            }
            Text("Code meanings come from the repair community, not from Apple, and can differ between models.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var panicSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "Kernel panics")
            if panics.isEmpty {
                Label("No kernel panic reports found.", systemImage: "checkmark.circle")
                    .foregroundStyle(TemperatureColor.cool)
            } else {
                ForEach(panics) { panic in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(panic.date.formatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                            if let area = panic.area {
                                Text(verbatim: CrashText.area(area))
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .foregroundStyle(TemperatureColor.hot)
                                    .background(TemperatureColor.hot.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                            }
                            Spacer()
                            Button(expanded == panic.id ? "Less" : "Full text") {
                                expanded = expanded == panic.id ? nil : panic.id
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        Text(verbatim: panic.summary)
                            .font(.caption.monospaced())
                            .lineLimit(expanded == panic.id ? nil : 2)
                            .textSelection(.enabled)
                        if let process = panic.panickedProcess {
                            Text(verbatim: process).font(.caption).foregroundStyle(.secondary)
                        }
                        if expanded == panic.id {
                            Text(verbatim: panic.panicString)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .padding(8)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(panic.panicString, forType: .string)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

/// Panics and shutdown causes found by the last scan (for reports).
struct CrashScan {
    let panics: [PanicReport]
    let shutdowns: [ShutdownEvent]
    var date = Date()
}

enum CrashText {
    static func shutdownMeaning(_ id: String?) -> String {
        switch id {
        case "normal": String(localized: "Normal shutdown")
        case "hardShutdown": String(localized: "Power button held (forced shutdown)")
        case "powerLoss": String(localized: "Power lost")
        case "overTemperature": String(localized: "Temperature limit exceeded (several sensors)")
        case "batteryEmpty": String(localized: "Battery empty")
        case "smcWatchdog": String(localized: "SMC / power management watchdog")
        case "watchdog": String(localized: "Watchdog — often logic board or RAM")
        case "memoryTemperature": String(localized: "Memory temperature limit exceeded")
        case "batteryTemperature": String(localized: "Battery temperature limit exceeded")
        case "adapterCommunication": String(localized: "Communication problem with the power adapter")
        case "adapterCurrent": String(localized: "Wrong current from the power adapter")
        case "batteryCurrent": String(localized: "Wrong current from the battery")
        case "proximityTemperature": String(localized: "Proximity sensor temperature exceeded")
        case "cpuTemperature": String(localized: "CPU temperature limit exceeded")
        case "powerSupplyTemperature": String(localized: "Power supply temperature exceeded")
        case "batteryCellVoltage": String(localized: "Battery cell under-voltage")
        case "battery": String(localized: "Battery problem")
        case "pmuForced": String(localized: "Forced shutdown by the PMU")
        case "unknownCritical": String(localized: "Unknown critical shutdown — often logic board")
        default: String(localized: "Unknown code")
        }
    }

    static func area(_ id: String) -> String {
        switch id {
        case "smc": String(localized: "SMC")
        case "aop": String(localized: "Always-On Processor")
        case "thermal": String(localized: "Thermal monitor")
        case "sleepwake": String(localized: "Sleep / wake")
        case "watchdog": String(localized: "Watchdog")
        case "ssd": String(localized: "SSD controller")
        case "display": String(localized: "Display")
        case "gpu": String(localized: "GPU")
        case "i2c": String(localized: "I2C bus")
        case "power": String(localized: "Power management")
        case "usb": String(localized: "USB-C / ports")
        case "wireless": String(localized: "Wi-Fi / Bluetooth")
        default: id
        }
    }
}
