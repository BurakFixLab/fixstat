import Foundation
import FixStatCore

/// The customer PDF report, drawn by the core `ReportPDF` (same output as the AppKit
/// interface).
@available(macOS 14.0, *)
enum PDFReport {
    @MainActor
    static func render(monitor: Monitor) -> Data? {
        ReportPDF.render(ReportData(monitor: monitor.core))
    }
}
