import AppKit
import CMacSensors
import MacSensors
import SwiftUI

/// What the trackpad test has seen so far.
struct TrackpadProgress: Equatable {
    static let columns = 16
    static let rows = 10
    /// Click zones: 3 × 3 over the surface.
    static let zoneColumns = 3
    static let zoneRows = 3
    static var zoneCount: Int { zoneColumns * zoneRows }

    var cells: Set<Int> = []
    var maxTouches = 0
    var leftZones: Set<Int> = []
    var rightZones: Set<Int> = []
    /// A click happened but no finger position was known (no multitouch data).
    var clickWithoutPosition = false
    var forceClick = false
    var scroll = false
    var pinch = false

    var coverage: Double { Double(cells.count) / Double(Self.columns * Self.rows) }
    var complete: Bool {
        cells.count == Self.columns * Self.rows && leftZones.count == Self.zoneCount
            && rightZones.count == Self.zoneCount && scroll
    }

    static func cell(x: Float, y: Float) -> Int {
        let column = min(columns - 1, max(0, Int(x * Float(columns))))
        let row = min(rows - 1, max(0, Int((1 - y) * Float(rows)))) // y origin is at the bottom
        return row * columns + column
    }

    static func zone(x: Float, y: Float) -> Int {
        let column = min(zoneColumns - 1, max(0, Int(x * Float(zoneColumns))))
        let row = min(zoneRows - 1, max(0, Int((1 - y) * Float(zoneRows))))
        return row * zoneColumns + column
    }
}

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
            surfaceMap
                .aspectRatio(1.6, contentMode: .fit)
                .frame(maxWidth: 560)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
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
            var parts = [String(localized: "Surface \(Format.percent(new.coverage * 100))"),
                         String(localized: "click zones left \(new.leftZones.count) / \(TrackpadProgress.zoneCount), right \(new.rightZones.count) / \(TrackpadProgress.zoneCount)")]
            if new.forceClick { parts.append(String(localized: "force click")) }
            if new.scroll { parts.append(String(localized: "scroll")) }
            if new.pinch { parts.append(String(localized: "pinch")) }
            monitor.recordCheck(.trackpad, detail: parts.joined(separator: " · "), passed: new.complete)
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

    private func pulse() {
        for delay in [0.3, 0.8, 1.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }
}

/// Raw contacts from MultitouchSupport (independent of the pointer position) plus
/// click / scroll / gesture events. A click is assigned to the zone under the pressing
/// finger (the largest contact) or, for a secondary click, under the fingers' centre.
@MainActor
@Observable
final class TrackpadTester {
    private(set) var progress = TrackpadProgress()
    private(set) var fingers: [FSTouch] = []
    private(set) var available: Bool?

    @ObservationIgnored private let buffer = TouchBuffer()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var monitors: [Any] = []
    @ObservationIgnored private var running = false

    func start() {
        guard !running else { return }
        running = true
        let callback: FSTouchCallback = { touches, count, _, context in
            guard let context else { return }
            Unmanaged<TouchBuffer>.fromOpaque(context).takeUnretainedValue()
                .store(Array(UnsafeBufferPointer(start: touches, count: Int(count))))
        }
        available = FSMultitouchStart(callback, Unmanaged.passUnretained(buffer).toOpaque())
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pull() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel, .magnify, .pressure]
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        } as Any)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        FSMultitouchStop()
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        fingers = []
    }

    func reset() {
        progress = TrackpadProgress()
        _ = buffer.take()
    }

    private func pull() {
        let (cells, maxTouches, current) = buffer.take()
        if current.map(\.identifier) != fingers.map(\.identifier)
            || zip(current, fingers).contains(where: { abs($0.x - $1.x) + abs($0.y - $1.y) > 0.002 }) {
            fingers = current
        }
        guard !cells.isSubset(of: progress.cells) || maxTouches > progress.maxTouches else { return }
        var next = progress
        next.cells.formUnion(cells)
        next.maxTouches = max(next.maxTouches, maxTouches)
        progress = next
    }

    private func handle(_ event: NSEvent) {
        var next = progress
        switch event.type {
        case .leftMouseDown where event.modifierFlags.contains(.control), .rightMouseDown:
            if let zone = zone(secondary: true) { next.rightZones.insert(zone) } else { next.clickWithoutPosition = true }
        case .leftMouseDown:
            if let zone = zone(secondary: false) { next.leftZones.insert(zone) } else { next.clickWithoutPosition = true }
        case .pressure:
            if event.stage >= 2 { next.forceClick = true }
        case .scrollWheel:
            if event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 2 { next.scroll = true }
        case .magnify:
            next.pinch = true
        default:
            break
        }
        if next != progress { progress = next }
    }

    /// Zone of the click from the most recent contacts (at most 0.5 s old).
    private func zone(secondary: Bool) -> Int? {
        let touches = buffer.recent(within: 0.5)
        guard !touches.isEmpty else { return nil }
        if secondary && touches.count >= 2 {
            let x = touches.map(\.x).reduce(0, +) / Float(touches.count)
            let y = touches.map(\.y).reduce(0, +) / Float(touches.count)
            return TrackpadProgress.zone(x: x, y: y)
        }
        guard let pressing = touches.max(by: { $0.size < $1.size }) else { return nil }
        return TrackpadProgress.zone(x: pressing.x, y: pressing.y)
    }
}

/// Written on the MultitouchSupport thread, read on the main thread.
final class TouchBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var cells: Set<Int> = []
    private var maxTouches = 0
    private var current: [FSTouch] = []
    /// Last frame that had contacts, and when (for clicks after the finger lifted).
    private var lastTouches: [FSTouch] = []
    private var lastTouchDate = Date.distantPast

    func store(_ touches: [FSTouch]) {
        lock.lock()
        defer { lock.unlock() }
        for t in touches { cells.insert(TrackpadProgress.cell(x: t.x, y: t.y)) }
        maxTouches = max(maxTouches, touches.count)
        current = touches
        if !touches.isEmpty {
            lastTouches = touches
            lastTouchDate = Date()
        }
    }

    /// New cells and the finger maximum since the last call, plus the current contacts.
    func take() -> (Set<Int>, Int, [FSTouch]) {
        lock.lock()
        defer { lock.unlock() }
        let result = (cells, maxTouches, current)
        cells = []
        maxTouches = 0
        return result
    }

    func recent(within seconds: TimeInterval) -> [FSTouch] {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastTouchDate) <= seconds ? lastTouches : []
    }
}
