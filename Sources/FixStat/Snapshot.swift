import AppKit
import SwiftUI

/// Renders the panel into a PNG without screen-recording permission:
///
///   FixStat.app/Contents/MacOS/FixStat --snapshot out.png [--technician] [--dark|--light]
///       [-AppleLanguages "(tr)"]
///
/// Used to check the UI and to produce README screenshots in each language.
@MainActor
enum Snapshot {
    static func runIfRequested(monitor: Monitor) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return }
        let url = URL(fileURLWithPath: arguments[index + 1])
        UserDefaults.standard.set(arguments.contains("--technician"), forKey: Pref.technicianMode)
        if arguments.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }

        let root = PanelView()
            .environment(monitor)
            .background(Color(nsColor: .windowBackgroundColor))
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
}
