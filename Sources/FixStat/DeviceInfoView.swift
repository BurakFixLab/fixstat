import AppKit
import MacSensors
import SwiftUI

/// Device card: identity, configuration, ownership / security and a health summary.
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
        var rows: [(String, String, Bool)] = []
        if let b = monitor.battery {
            let check = PartCheck.battery(b, model: monitor.system.model, reference: monitor.partsReference)
            var parts = [b.healthPercent.map { Format.percent($0, digits: 1) },
                         b.cycleCount.map { String(localized: "\($0) cycles") }].compactMap { $0 }
            parts.append(PartText.verdict(check.verdict))
            rows.append((String(localized: "Battery"), parts.joined(separator: " · "),
                         (b.healthPercent ?? 100) < 80 || check.verdict == .suspicious))
        }
        if let h = ssd?.health {
            let findings = SSDText.healthFindings(h)
            rows.append((String(localized: "SSD"), findings.isEmpty
                         ? String(localized: "SSD health is good.") + " " + String(localized: "\(h.percentageUsed) % used")
                         : findings.joined(separator: " "), !findings.isEmpty))
        }
        if let panics {
            let recent = panics.filter { $0.date > Date().addingTimeInterval(-30 * 86_400) }
            rows.append((String(localized: "Kernel panics (30 days)"),
                         recent.isEmpty ? String(localized: "none") : Format.number(Double(recent.count)), !recent.isEmpty))
        }
        let check = monitor.hardwareCheck
        if !check.isEmpty {
            rows.append((String(localized: "Hardware check"),
                         String(localized: "\(check.count(.passed)) passed · \(check.count(.failed)) failed · \(check.count(.untested)) not tested"),
                         check.hasFailures))
        }
        return rows
    }
}

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

enum DeviceText {
    static func configuration(_ info: DeviceInfo, ssd: SSDInfo?) -> [(String, String)] {
        var rows: [(String, String)] = [(String(localized: "Chip"), info.system.chip)]
        if let p = info.performanceCores, let e = info.efficiencyCores {
            rows.append((String(localized: "CPU cores"),
                         String(localized: "\(p + e) (\(p) performance, \(e) efficiency)")))
        }
        if let gpu = info.gpuCores { rows.append((String(localized: "GPU cores"), Format.number(Double(gpu)))) }
        if let memory = info.memoryBytes { rows.append((String(localized: "Memory"), Format.memory(memory))) }
        if let ssd {
            rows.append((String(localized: "SSD"), [ssd.capacity.map { Format.bytes($0) }, ssd.model]
                .compactMap { $0 }.joined(separator: " · ")))
        }
        if let firmware = info.firmwareVersion { rows.append((String(localized: "Firmware (iBoot)"), firmware)) }
        rows.append((String(localized: "macOS"), info.system.osVersion))
        return rows
    }

    /// (title, value, needs attention)
    static func security(_ info: DeviceInfo) -> [(String, String, Bool)] {
        [
            (String(localized: "Activation Lock (Find My)"), state(info.activationLock,
                on: String(localized: "On — the owner must turn it off"), off: String(localized: "Off")),
             info.activationLock == .on),
            (String(localized: "MDM enrollment"), state(info.mdmEnrolled,
                on: String(localized: "Enrolled — managed by an organisation"), off: String(localized: "Not enrolled")),
             info.mdmEnrolled == .on),
            (String(localized: "Automated enrollment (DEP)"), state(info.depEnrolled,
                on: String(localized: "Yes"), off: String(localized: "No")), info.depEnrolled == .on),
            (String(localized: "System Integrity Protection"), state(info.sipEnabled,
                on: String(localized: "On"), off: String(localized: "Off — modified system")), info.sipEnabled == .off),
            (String(localized: "FileVault"), state(info.fileVault,
                on: String(localized: "On — the user password is needed to reach the data"), off: String(localized: "Off")),
             false),
        ]
    }

    static func state(_ s: DeviceInfo.SecurityState, on: String, off: String) -> String {
        switch s {
        case .on: on
        case .off: off
        case .unknown: String(localized: "unknown")
        }
    }

    /// For pasting into a work order.
    static func plainText(_ info: DeviceInfo, ssd: SSDInfo?, health: [(String, String, Bool)]) -> String {
        var lines = [info.system.marketingName ?? info.system.model,
                     [info.system.model, info.system.boardTarget, info.partNumber].compactMap { $0 }.joined(separator: " · ")]
        if let serial = info.serial { lines.append(String(localized: "Serial \(serial)")) }
        lines.append("")
        lines += configuration(info, ssd: ssd).map { "\($0.0): \($0.1)" }
        lines.append("")
        lines += security(info).map { "\($0.0): \($0.1)" }
        lines.append("")
        lines += health.map { "\($0.0): \($0.1)" }
        return lines.joined(separator: "\n")
    }
}
