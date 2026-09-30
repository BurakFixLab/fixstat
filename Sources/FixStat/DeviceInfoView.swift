import AppKit
import MacSensors
import SwiftUI
import FixStatCore

/// Device card: identity, configuration, ownership / security and a health summary.
@available(macOS 14.0, *)
struct DeviceInfoView: View {
    static let windowID = "device"

    @Environment(Monitor.self) private var monitor
    @State private var ssd: SSDInfo?
    @State private var panics: [PanicReport]?
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let info = monitor.deviceInfo {
                    header(info)
                    section("Configuration", DeviceText.configuration(info, ssd: ssd))
                    SectionTitle(title: "Ownership and security")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(DeviceText.security(info), id: \.0) { row in
                            SecurityRow(title: row.0, value: row.1, attention: row.2)
                        }
                    }
                    SectionTitle(title: "Health summary")
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(healthRows.enumerated()), id: \.offset) { _, row in
                            SecurityRow(title: row.0, value: row.1, attention: row.2)
                        }
                    }
                    HStack {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DeviceText.plainText(info, ssd: ssd, health: healthRows), forType: .string)
                            copied = true
                        } label: {
                            Label(copied ? "Copied" : "Copy as text", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        Spacer()
                        ExportMenu()
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 560)
        .monospacedDigit()
        .task {
            await monitor.loadDeviceInfo()
            ssd = await Task.detached { SSDInfo.read() }.value
            panics = await Task.detached { CrashHistory.panics() }.value
        }
    }

    private func header(_ info: DeviceInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: info.system.marketingName ?? info.system.model)
                .font(.title2.weight(.semibold))
            Text(verbatim: [info.system.model, info.system.boardTarget, info.partNumber].compactMap { $0 }
                .joined(separator: " · "))
                .foregroundStyle(.secondary)
            if let serial = info.serial {
                Text("Serial \(serial)").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func section(_ title: LocalizedStringKey, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: title)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(verbatim: row.0).foregroundStyle(.secondary)
                        Text(verbatim: row.1).textSelection(.enabled)
                    }
                }
            }
            .font(.callout)
        }
    }

    /// (title, value, needs attention)
    private var healthRows: [(String, String, Bool)] {
        DeviceText.healthRows(battery: monitor.battery, model: monitor.system.model, reference: monitor.partsReference,
                              ssd: ssd, panics: panics, hardwareCheck: monitor.hardwareCheck)
    }
}

@available(macOS 14.0, *)
private struct SecurityRow: View {
    let title: String
    let value: String
    let attention: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: attention ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(attention ? TemperatureColor.hot : TemperatureColor.cool)
            Text(verbatim: title).frame(width: 190, alignment: .leading)
            Text(verbatim: value).foregroundStyle(attention ? AnyShapeStyle(TemperatureColor.hot) : AnyShapeStyle(.primary))
        }
        .font(.callout)
    }
}
