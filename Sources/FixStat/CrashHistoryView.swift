import AppKit
import MacSensors
import SwiftUI
import FixStatCore

/// Kernel panics and previous shutdown causes.
@available(macOS 14.0, *)
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
@available(macOS 14.0, *)
struct CrashScan {
    let panics: [PanicReport]
    let shutdowns: [ShutdownEvent]
    var date = Date()
}
