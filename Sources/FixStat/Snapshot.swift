import AppKit
import MacSensors
import SwiftUI
import FixStatCore

/// Renders the panel into a PNG without screen-recording permission:
///
///   FixStat.app/Contents/MacOS/FixStat --snapshot out.png [--technician] [--settings TAB]
///       [--dark|--light] [-AppleLanguages "(tr)"]
///
/// `--settings 0|1|2` renders a Settings tab (General, Thresholds, Sensors) instead,
/// `--details` the battery details window, `--power` the power analysis window, `--sleep-window` the sleep and wake window, `--ssd-window` the SSD window, `--memory-window`, `--test-window`, `--capacity-window` the test windows, `--hardware [keyboard|trackpad|…]` the hardware check, `--history [--range 0…6]` the battery history window (use `--data-dir DIR` for sample data).
///
///   FixStat.app/Contents/MacOS/FixStat --export report.csv|report.json|report.pdf [--sample-check] [--sample-capacity] [--sleep]
///
/// writes the same report as "Export report" (serials masked) and exits.
///
/// Used to check the UI and to produce README screenshots in each language.
@available(macOS 14.0, *)
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
        if let i = arguments.firstIndex(of: "--hardware") {
            let item = (i + 1 < arguments.count ? HardwareCheck.Item(rawValue: arguments[i + 1]) : nil)
            root = AnyView(HardwareCheckView(initialItem: item)
                .environment(monitor)
                .frame(width: 900, height: 680)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--memory-window") {
            root = AnyView(MemoryView()
                .environment(MemoryTestRunner(monitor: monitor))
                .frame(width: 580, height: 480)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--test-window") {
            root = AnyView(TestView()
                .environment(monitor)
                .environment(TestRunner(monitor: monitor))
                .frame(width: 640, height: 640)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--capacity-window") {
            root = AnyView(CapacityTestView()
                .environment(monitor)
                .environment(CapacityTestRunner(monitor: monitor))
                .frame(width: 680, height: 760)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--ssd-window") {
            root = AnyView(SSDView()
                .environment(SSDTestRunner(monitor: monitor))
                .environment(FullSSDTestRunner(monitor: monitor))
                .frame(width: 660, height: 1100)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--sleep-window") {
            root = AnyView(SleepView()
                .environment(monitor)
                .frame(width: 720, height: 1500)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--power") {
            root = AnyView(PowerView()
                .frame(width: 680, height: 760)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else if arguments.contains("--details") {
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
            // As if the panel were open, so CPU and memory are polled too.
            monitor.panelVisible = true
            root = AnyView(PanelView()
                .environment(monitor)
                .environment(TestRunner(monitor: monitor))
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000)) // off screen
        window.orderFrontRegardless()

        // Wait for two refreshes after the sensors are ready (CPU usage needs a delta). The
        // panel's window observer sees the off-screen window as hidden, so mark it open again.
        let panel = monitor.panelVisible  // set above for the panel only
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if panel { monitor.panelVisible = true }
            monitor.refresh()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if panel { monitor.panelVisible = true }
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

    /// Synthetic checklist for screenshots and PDF checks (`--sample-check`).
    static func sampleCheck() -> HardwareCheck {
        var check = HardwareCheck(profile: .current())
        check[.keyboard] = .init(status: .passed, detail: String(localized: "\(78) / \(78) keys"))
        check[.trackpad] = .init(status: .passed, detail: String(localized: "Surface \(Format.percent(100))"))
        check[.display] = .init(status: .failed, note: "Sample: bright spot near the lower left corner")
        check[.speakers] = .init(status: .passed)
        check[.camera] = .init(status: .skipped)
        return check
    }

    /// Synthetic capacity test (`--sample-capacity`): 2 A for 90 min, 100 → 20 %.
    static func sampleCapacity() -> CapacityResult {
        var samples = [CapacitySample(time: 0, voltage: 12_700, amperage: -350, percent: 100, remaining: 3200,
                                      cells: [4230, 4235, 4235], temperature: 30, idle: true)]
        for step in 0...540 {
            let f = Double(step) / 540
            samples.append(CapacitySample(time: 30 + Double(step) * 10, voltage: 12_300 - Int(1200 * f), amperage: -2000,
                                          percent: 100 - 80 * f, remaining: 3200 - Int(2950 * f),
                                          cells: [4100 - Int(400 * f), 4090 - Int(420 * f), 4100 - Int(400 * f)],
                                          temperature: 33, idle: false))
        }
        return CapacityResult.compute(samples: samples, startedAt: Date(), stopReason: .targetReached,
                                      fullChargeCapacity: 3213, designCapacity: 4382)
    }

    static func export(to url: URL, monitor: Monitor) {
        monitor.panelVisible = true
        if CommandLine.arguments.contains("--sample-check") { monitor.hardwareCheck = sampleCheck() }
        if CommandLine.arguments.contains("--sleep") { monitor.lastSleepAnalysis = SleepAnalysis.read() }
        if CommandLine.arguments.contains("--sample-capacity") { monitor.lastCapacityResult = sampleCapacity() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            monitor.refresh()
            let report = SensorReport(monitor: monitor.core)
            do {
                let data: Data
                switch url.pathExtension.lowercased() {
                case "csv": data = report.csv()
                case "pdf": data = PDFReport.render(monitor: monitor) ?? Data()
                default: data = try report.json()
                }
                try data.write(to: url)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("export failed: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}
