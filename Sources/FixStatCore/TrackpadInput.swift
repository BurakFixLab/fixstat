import AppKit
import CMacSensors
import MacSensors

// Trackpad test input, shared by both interfaces.

/// What the trackpad test has seen so far.
public struct TrackpadProgress: Equatable {
    public static let columns = 16
    public static let rows = 10
    /// Click zones: 3 × 3 over the surface.
    public static let zoneColumns = 3
    public static let zoneRows = 3
    public static var zoneCount: Int { zoneColumns * zoneRows }

    public var cells: Set<Int> = []
    public var maxTouches = 0
    public var leftZones: Set<Int> = []
    public var rightZones: Set<Int> = []
    /// A click happened but no finger position was known (no multitouch data).
    public var clickWithoutPosition = false
    public var forceClick = false
    public var scroll = false
    public var pinch = false

    public var coverage: Double { Double(cells.count) / Double(Self.columns * Self.rows) }
    public var complete: Bool {
        cells.count == Self.columns * Self.rows && leftZones.count == Self.zoneCount
            && rightZones.count == Self.zoneCount && scroll
    }

    public static func cell(x: Float, y: Float) -> Int {
        let column = index(x, count: columns)
        let row = index(1 - y, count: rows) // y origin is at the bottom
        return row * columns + column
    }

    public static func zone(x: Float, y: Float) -> Int {
        let column = index(x, count: zoneColumns)
        let row = index(1 - y, count: zoneRows)
        return row * zoneColumns + column
    }

    /// 0…count-1 for a position 0…1; clamped before the conversion, so a NaN or an
    /// out-of-range value from the framework cannot trap in Int().
    private static func index(_ position: Float, count: Int) -> Int {
        guard position.isFinite else { return 0 }
        let clamped = min(max(position, 0), 0.9999)
        return min(count - 1, Int(clamped * Float(count)))
    }

    public init() {}

    /// Evidence for the report.
    public var detail: String {
        var parts = [L("Surface %@", Format.percent(coverage * 100)),
                     L("click zones left %lld / %lld, right %lld / %lld", leftZones.count, Self.zoneCount,
                       rightZones.count, Self.zoneCount)]
        if forceClick { parts.append(L("force click")) }
        if scroll { parts.append(L("scroll")) }
        if pinch { parts.append(L("pinch")) }
        return parts.joined(separator: " · ")
    }
}

/// Raw contacts from MultitouchSupport (independent of the pointer position) plus
/// click / scroll / gesture events. A click is assigned to the zone under the pressing
/// finger (the largest contact) or, for a secondary click, under the fingers' centre.
public final class TrackpadRecorder {
    public private(set) var progress = TrackpadProgress()
    public private(set) var fingers: [FSTouch] = []
    public private(set) var available: Bool?
    /// Called on the main thread when the progress or the live fingers changed.
    public var onChange: (() -> Void)?

    private let buffer = TouchBuffer()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var running = false
    private var ticksSinceRetry = 0

    public init() {}

    public func start() {
        guard !running else { return }
        running = true
        openDevice()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.pull()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .scrollWheel, .magnify, .pressure]
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
            return event
        } as Any)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.handle(event)
        }) {
            monitors.append(global)
        }
    }

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(buffer).toOpaque() }

    private func openDevice() {
        let callback: FSTouchCallback = { touches, count, _, context in
            guard let context else { return }
            Unmanaged<TouchBuffer>.fromOpaque(context).takeUnretainedValue()
                .store(Array(UnsafeBufferPointer(start: touches, count: Int(count))))
        }
        available = FSMultitouchStart(callback, context)
        ticksSinceRetry = 0
    }

    public func stop() {
        guard running else { return }
        running = false
        FSMultitouchStop(context)
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        fingers = []
    }

    public func reset() {
        progress = TrackpadProgress()
        _ = buffer.take()
        // Also a way out when the trackpad could not be opened: try again.
        if running, available != true { openDevice() }
        onChange?()
    }

    private func pull() {
        // The device can be briefly unavailable (e.g. right after a wake): retry every 2 s.
        if available == false {
            ticksSinceRetry += 1
            if ticksSinceRetry >= 60 {
                openDevice()
                if available == true { onChange?() }
            }
        }
        let (cells, maxTouches, current) = buffer.take()
        var changed = false
        if current.map(\.identifier) != fingers.map(\.identifier)
            || zip(current, fingers).contains(where: { abs($0.x - $1.x) + abs($0.y - $1.y) > 0.002 }) {
            fingers = current
            changed = true
        }
        if !cells.isSubset(of: progress.cells) || maxTouches > progress.maxTouches {
            progress.cells.formUnion(cells)
            progress.maxTouches = max(progress.maxTouches, maxTouches)
            changed = true
        }
        if changed { onChange?() }
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
        if next != progress {
            progress = next
            onChange?()
        }
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

extension TrackpadRecorder {
    /// Three haptic pulses: felt with a finger resting on a Force Touch trackpad.
    public static func pulse() {
        for delay in [0.3, 0.8, 1.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        }
    }
}
