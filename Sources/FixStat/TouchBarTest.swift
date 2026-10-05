import FixStatCore
import MacSensors
import SwiftUI

/// Touch Bar: touch cells and solid colours on the bar (core `TouchBarTester`).
@available(macOS 14.0, *)
struct TouchBarTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var tester = TouchBarTesterModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                ForEach(0..<TouchBarTester.cellCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tester.touched.contains(index) ? AnyShapeStyle(TemperatureColor.cool) : AnyShapeStyle(.quaternary))
                }
            }
            .frame(height: 24)
            Text(verbatim: tester.progress).foregroundStyle(.secondary)
            if tester.active, !tester.fullWidth {
                Label("The Touch Bar could not be shown full width: keep this window in front.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Start touch test") { tester.startTouchTest() }
                ForEach(TouchBarTester.colours.indices, id: \.self) { index in
                    Button(TouchBarText.colourName(index)) { tester.showColour(index) }
                }
                if tester.active {
                    Button("Stop") { tester.stop() }
                }
            }
        }
        .font(.callout)
        .onDisappear { tester.stop() }
        .onChange(of: tester.touched) { _, touched in
            guard tester.touchMode else { return }
            monitor.recordCheck(.touchBar, detail: tester.progress, passed: touched.count == TouchBarTester.cellCount)
        }
    }
}

/// SwiftUI view of the core `TouchBarTester`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class TouchBarTesterModel {
    private(set) var touched = Set<Int>()
    private(set) var active = false
    private(set) var touchMode = false
    private(set) var fullWidth = false
    private(set) var progress = ""

    @ObservationIgnored private let tester = TouchBarTester()

    init() {
        tester.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
        sync()
    }

    func startTouchTest() { tester.startTouchTest() }
    func showColour(_ index: Int) { tester.showColour(index) }
    func stop() { tester.stop() }

    private func sync() {
        if tester.touched != touched { touched = tester.touched }
        if (tester.mode != .off) != active { active = tester.mode != .off }
        if (tester.mode == .touch) != touchMode { touchMode = tester.mode == .touch }
        if tester.fullWidth != fullWidth { fullWidth = tester.fullWidth }
        let text = TouchBarText.progress(tester)
        if text != progress { progress = text }
    }
}
