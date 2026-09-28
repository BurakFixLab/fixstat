import AppKit
import SwiftUI

/// Renders the panel into a PNG without screen-recording permission:
///
///   FixStat.app/Contents/MacOS/FixStat --snapshot out.png [--technician] [--settings TAB]
///       [--dark|--light] [-AppleLanguages "(tr)"]
///
/// `--settings 0|1|2` renders a Settings tab (General, Thresholds, Sensors) instead,
/// `--details` the battery details window, `--history [--range 0…6]` the battery history window (use `--data-dir DIR` for sample data).
///
///   FixStat.app/Contents/MacOS/FixStat --export report.csv|report.json
///
/// writes the same report as "Export report" (serials masked) and exits.
///
/// Used to check the UI and to produce README screenshots in each language.
@MainActor
enum Snapshot {
    static func runIfRequested(monitor: Monitor) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--export"), index + 1 < arguments.count {
            export(to: URL(fileURLWithPath: arguments[index + 1]), monitor: monitor)
            return
        }
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1])
        UserDefaults.standard.set(arguments.contains("--technician"), forKey: Pref.technicianMode)
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }

        let settingsTab = arguments.firstIndex(of: "--settings").flatMap { i in
            i + 1 < arguments.count ? Int(arguments[i + 1]) : nil
        }
        let root: AnyView
        if arguments.contains("--details") {
            root = AnyView(BatteryDetailsView()
                .environment(monitor)
                .frame(width: 720, height: 760)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--history") {
            let rangeIndex = arguments.firstIndex(of: "--range").flatMap { i in
                i + 1 < arguments.count ? Int(arguments[i + 1]) : nil
            }
            root = AnyView(HistoryView(initialRange: rangeIndex.flatMap(HistoryView.Range.init(rawValue:)) ?? .day)
                .environment(monitor)
                .frame(width: 680, height: 700)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if let settingsTab {
            root = AnyView(SettingsView(initialTab: settingsTab)
                .environment(monitor)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else {
            root = AnyView(PanelView()
                .environment(monitor)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000)) // off screen
        window.orderFrontRegardless()

        // Wait for two refreshes (CPU usage needs a delta).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            monitor.refresh()
            window.setContentSize(host.fittingSize)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
                host.cacheDisplay(in: host.bounds, to: rep)
                do {
                    try rep.representation(using: .png, properties: [:])?.write(to: url)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    static func export(to url: URL, monitor: Monitor) {
        monitor.panelVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            monitor.refresh()
            let report = SensorReport(monitor: monitor)
            do {
                let data = url.pathExtension.lowercased() == "csv" ? report.csv() : try report.json()
                try data.write(to: url)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}
