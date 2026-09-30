import AppKit
import MacSensors
import SwiftUI
import UniformTypeIdentifiers
import FixStatCore

/// "Export report" menu with CSV and JSON.
@available(macOS 14.0, *)
struct ExportMenu: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Menu("Export report") {
            Button("PDF…") { exportPDF() }
            Button("CSV…") { export(csv: true) }
            Button("JSON…") { export(csv: false) }
        }
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    private func exportPDF() {
        guard let data = PDFReport.render(monitor: monitor) else { return }
        save(data, type: .pdf, extension: "pdf")
    }

    private func save(_ data: Data, type: UTType, extension ext: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = SensorReport.fileName(model: monitor.system.model, fileExtension: ext)
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func export(csv: Bool) {
        let report = SensorReport(monitor: monitor.core)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        panel.nameFieldStringValue = SensorReport.fileName(model: monitor.system.model, fileExtension: csv ? "csv" : "json")
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (csv ? report.csv() : report.json()).write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
