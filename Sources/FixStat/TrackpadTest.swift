import AppKit
import CMacSensors
import MacSensors
import SwiftUI
import FixStatCore

@available(macOS 14.0, *)
struct TrackpadTestView: View {
    @Environment(Monitor.self) private var monitor
    @State private var tester = TrackpadTester()

    var body: some View {
        let progress = tester.progress
        VStack(alignment: .leading, spacing: 12) {
            if tester.available == false {
                Label("Raw trackpad data is not available on this Mac; only clicks and gestures are checked.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(TemperatureColor.hot)
            }
            // The card hugs the map: when the pane is short the map gets narrower than 560,
            // and a card around the wider frame left empty strips at both sides.
            surfaceMap
                .aspectRatio(1.6, contentMode: .fit)
                .background(Design.cardFill)
                .clipShape(RoundedRectangle(cornerRadius: Design.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).strokeBorder(.separator, lineWidth: 0.5))
                .frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 14) {
                Text("Click zones: left \(progress.leftZones.count) / \(TrackpadProgress.zoneCount) · right \(progress.rightZones.count) / \(TrackpadProgress.zoneCount)")
                check("Force click", progress.forceClick)
                check("Scroll", progress.scroll)
                check("Pinch", progress.pinch)
            }
            .font(.callout)
            HStack {
                Text("Surface \(Format.percent(progress.coverage * 100)) · up to \(progress.maxTouches) fingers")
                Spacer()
                Button("Haptic feedback") { pulse() }
                    .help(Text("Keep a finger resting on the trackpad: three taps should be felt."))
                Button("Reset") { tester.reset() }
            }
        }
        .onAppear { tester.start() }
        .onDisappear { tester.stop() }
        .onChange(of: progress) { _, new in
            monitor.recordCheck(.trackpad, detail: new.detail, passed: new.complete)
        }
    }

    /// Touched cells, the 3 × 3 click zones with their left / right marks and the live fingers.
    private var surfaceMap: some View {
        Canvas { context, size in
            let progress = tester.progress
            let w = size.width / CGFloat(TrackpadProgress.columns)
            let h = size.height / CGFloat(TrackpadProgress.rows)
            for cell in progress.cells {
                let rect = CGRect(x: CGFloat(cell % TrackpadProgress.columns) * w,
                                  y: CGFloat(cell / TrackpadProgress.columns) * h, width: w, height: h)
                context.fill(Path(rect.insetBy(dx: 1, dy: 1)), with: .color(TemperatureColor.cool.opacity(0.45)))
            }
            var grid = Path()
            for c in 1..<TrackpadProgress.columns {
                grid.move(to: CGPoint(x: CGFloat(c) * w, y: 0))
                grid.addLine(to: CGPoint(x: CGFloat(c) * w, y: size.height))
            }
            for r in 1..<TrackpadProgress.rows {
                grid.move(to: CGPoint(x: 0, y: CGFloat(r) * h))
                grid.addLine(to: CGPoint(x: size.width, y: CGFloat(r) * h))
            }
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)

            let zw = size.width / CGFloat(TrackpadProgress.zoneColumns)
            let zh = size.height / CGFloat(TrackpadProgress.zoneRows)
            var zones = Path()
            for c in 1..<TrackpadProgress.zoneColumns {
                zones.move(to: CGPoint(x: CGFloat(c) * zw, y: 0))
                zones.addLine(to: CGPoint(x: CGFloat(c) * zw, y: size.height))
            }
            for r in 1..<TrackpadProgress.zoneRows {
                zones.move(to: CGPoint(x: 0, y: CGFloat(r) * zh))
                zones.addLine(to: CGPoint(x: size.width, y: CGFloat(r) * zh))
            }
            context.stroke(zones, with: .color(.secondary.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            for zone in 0..<TrackpadProgress.zoneCount {
                let center = CGPoint(x: (CGFloat(zone % TrackpadProgress.zoneColumns) + 0.5) * zw,
                                     y: (CGFloat(zone / TrackpadProgress.zoneColumns) + 0.5) * zh)
                badge(context, Text("Left"), at: CGPoint(x: center.x - 30, y: center.y), done: progress.leftZones.contains(zone))
                badge(context, Text("Right"), at: CGPoint(x: center.x + 30, y: center.y), done: progress.rightZones.contains(zone))
            }
            for finger in tester.fingers {
                let p = CGPoint(x: CGFloat(finger.x) * size.width, y: (1 - CGFloat(finger.y)) * size.height)
                context.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)),
                             with: .color(TemperatureColor.warm.opacity(0.9)))
            }
        }
    }

    private func badge(_ context: GraphicsContext, _ text: Text, at point: CGPoint, done: Bool) {
        let rect = CGRect(x: point.x - 26, y: point.y - 11, width: 52, height: 22)
        context.fill(Path(roundedRect: rect, cornerRadius: 11),
                     with: .color(done ? TemperatureColor.cool : Color.secondary.opacity(0.2)))
        context.draw(text.font(.caption.weight(.semibold)).foregroundStyle(done ? Color.white : Color.secondary),
                     at: point)
    }

    private func check(_ title: LocalizedStringKey, _ done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(done ? AnyShapeStyle(TemperatureColor.cool) : AnyShapeStyle(.secondary))
    }

    private func pulse() { TrackpadRecorder.pulse() }
}

/// SwiftUI view of the core `TrackpadRecorder`.
@available(macOS 14.0, *)
@MainActor
@Observable
final class TrackpadTester {
    private(set) var progress = TrackpadProgress()
    private(set) var fingers: [FSTouch] = []
    private(set) var available: Bool?

    @ObservationIgnored private let recorder = TrackpadRecorder()

    init() {
        recorder.onChange = { [weak self] in
            MainActor.assumeIsolated { self?.sync() }
        }
    }

    func start() {
        recorder.start()
        sync()
    }

    func stop() {
        recorder.stop()
        sync()
    }

    func reset() { recorder.reset() }

    private func sync() {
        if recorder.progress != progress { progress = recorder.progress }
        fingers = recorder.fingers
        if recorder.available != available { available = recorder.available }
    }
}
