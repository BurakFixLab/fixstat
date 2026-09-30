import AppKit
import CMacSensors
import MacSensors
import FixStatCore

// MARK: - Keyboard

/// Keyboard test: draws the built-in keyboard and marks every key that registered.
final class LegacyKeyboardPane: BlockPane {
    private let drawing = KeyboardDrawingView()
    private var pressed: Set<Int> = []
    private var held: Set<Int> = []
    private var eventMonitor: Any?
    private let tap = KeyEventTap()
    private var retry: Timer?
    private let kind = KeyLegend.kind
    /// True while the hardware check window is key and no text field is being edited.
    var isFocused: () -> Bool = { false }

    private var total: Int { KeyboardLayout.codes(kind).count }

    override init(core: MonitorCore) {
        super.init(core: core)
        drawing.kind = kind
        drawing.translatesAutoresizingMaskIntoConstraints = false
        drawing.heightAnchor.constraint(equalTo: drawing.widthAnchor, multiplier: 5.65 / 14.5).isActive = true
    }

    override func blocks() -> [Block] {
        drawing.pressed = pressed
        drawing.held = held
        let reset = ActionButton(title: L("Reset keys")) { [unowned self] in
            pressed = []
            held = []
            refresh()
        }
        reset.isEnabled = !pressed.isEmpty
        var blocks: [Block] = [
            .view(drawing),
            .view(hStack([makeLabel(KeyboardLayout.progress(pressed.count, of: total), weight: .semibold),
                          makeLabel(KeyLegend.layoutName, size: LegacyStyle.caption, color: .secondaryLabelColor),
                          makeSpacer(), reset])),
        ]
        switch tap.mode {
        case .none:
            blocks.append(.status(L("Keys used by macOS (e.g. F3–F6 without fn) need the Input Monitoring permission."), .neutral))
            blocks.append(.actions([DocAction(title: L("Allow…")) { KeyEventTap.requestAccess() }]))
        case .listenOnly:
            blocks.append(.status(L("All keys are detected. macOS still acts on its own keys (Mission Control, Spotlight …); allow FixStat under Accessibility to block that during the test."), .neutral))
        case .active:
            break
        }
        return blocks
    }

    override func activate() {
        install()
        super.activate()
    }

    override func deactivate() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        tap.stop()
        retry?.invalidate()
        retry = nil
    }

    private func install() {
        guard eventMonitor == nil else { return }
        drawing.legends = KeyLegend.legends()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .systemDefined]) { [weak self] event in
            guard let self, isFocused() else { return event }
            handle(event)
            // No shortcuts while testing.
            return event.type == .keyDown || event.type == .keyUp ? nil : event
        }
        tap.handler = { [weak self] event in
            guard let self, isFocused() else { return false }
            handle(event)
            // With an active tap, keep macOS from opening Mission Control, Spotlight, …
            return event.type == .keyDown || event.type == .keyUp
                || (event.type == .systemDefined && event.subtype.rawValue == 8)
        }
        startTap()
    }

    private func startTap() {
        tap.start()
        retry?.invalidate()
        retry = nil
        guard tap.mode == .none else { return }
        // Picks up the permission as soon as it is granted in System Settings.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            tap.start()
            if tap.mode != .none {
                retry?.invalidate()
                retry = nil
                refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        retry = timer
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            register(KeyLegend.physicalCode(Int(event.keyCode)), down: true)
        case .keyUp:
            held.remove(KeyLegend.physicalCode(Int(event.keyCode)))
            drawing.held = held
        case .flagsChanged:
            let code = Int(event.keyCode)
            guard let down = KeyLegend.isModifierDown(code, flags: event.modifierFlags) else { return }
            register(code, down: down)
        case .systemDefined:
            // Media keys (top row without fn): subtype 8, key type in data1's high word.
            guard event.subtype.rawValue == 8 else { return }
            let keyType = (event.data1 & 0xFFFF_0000) >> 16
            let state = (event.data1 & 0xFF00) >> 8
            guard let code = KeyLegend.mediaKeyCodes[keyType] else { return }
            register(code, down: state == 0x0A)
        default:
            break
        }
    }

    private func register(_ code: Int, down: Bool) {
        guard KeyboardLayout.codes(kind).contains(code) else { return }
        if down {
            held.insert(code)
            if pressed.insert(code).inserted {
                core.recordCheck(.keyboard, detail: KeyboardLayout.progress(pressed.count, of: total),
                                 passed: pressed.count == total)
                refresh()
            }
        } else {
            held.remove(code)
        }
        drawing.held = held
    }
}

/// Draws the keyboard rows, 14.5 units wide.
final class KeyboardDrawingView: NSView {
    var kind = KeyboardLayout.Kind.ansi { didSet { needsDisplay = true } }
    var pressed: Set<Int> = [] { didSet { if pressed != oldValue { needsDisplay = true } } }
    var held: Set<Int> = [] { didSet { if held != oldValue { needsDisplay = true } } }
    var legends: [Int: String] = [:] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let unit = bounds.width / 14.5
        let gap = unit * 0.1
        var y: CGFloat = 0
        for (index, row) in KeyboardLayout.rows(kind).enumerated() {
            let height = (index == 0 ? 0.55 : 0.9) * unit
            var x: CGFloat = 0
            var halfColumn: (x: CGFloat, count: Int)?
            for key in row {
                if key.halfHeight {
                    // Up / Down share one column, stacked.
                    if let column = halfColumn, column.count == 1 {
                        drawKey(key, NSRect(x: column.x, y: y + (height + gap / 2) / 2, width: unit - gap,
                                            height: (height - gap / 2) / 2))
                        halfColumn = nil
                        continue
                    }
                    drawKey(key, NSRect(x: x, y: y, width: unit - gap, height: (height - gap / 2) / 2))
                    halfColumn = (x, 1)
                    x += unit
                } else {
                    halfColumn = nil
                    drawKey(key, NSRect(x: x, y: y, width: key.width * unit - gap, height: height))
                    x += key.width * unit
                }
            }
            y += height + gap
        }
    }

    private func drawKey(_ key: KeyboardLayout.Key, _ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let isPressed = pressed.contains(key.code)
        if isPressed {
            LegacyStyle.cool.withAlphaComponent(held.contains(key.code) ? 1 : 0.7).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
        }
        path.fill()
        if key.code == KeyboardLayout.touchIDPlaceholder {
            NSColor.tertiaryLabelColor.setStroke()
            path.setLineDash([3, 3], count: 2, phase: 0)
            path.stroke()
        }
        let legend = key.legend ?? legends[key.code] ?? ""
        guard !legend.isEmpty else { return }
        var size = min(rect.height * 0.42, 13)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: isPressed ? NSColor.white : NSColor.secondaryLabelColor,
        ]
        var textSize = (legend as NSString).size(withAttributes: attributes)
        if textSize.width > rect.width - 4 {
            size *= max(0.5, (rect.width - 4) / textSize.width)
            attributes[.font] = NSFont.systemFont(ofSize: size, weight: .medium)
            textSize = (legend as NSString).size(withAttributes: attributes)
        }
        (legend as NSString).draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
                                  withAttributes: attributes)
    }
}

// MARK: - Trackpad

final class LegacyTrackpadPane: BlockPane {
    private let recorder = TrackpadRecorder()
    private let surface = TrackpadSurfaceView()
    private var lastProgress = TrackpadProgress()
    private var shownAvailable: Bool??
    private var evidencePending = false
    // Updated in place: rebuilding the pane for every touched cell stalled older Macs.
    private let zonesLabel = makeLabel("")
    private let forceLabel = makeLabel("")
    private let scrollLabel = makeLabel("")
    private let pinchLabel = makeLabel("")
    private let surfaceLabel = makeLabel("")

    override init(core: MonitorCore) {
        super.init(core: core)
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.heightAnchor.constraint(equalTo: surface.widthAnchor, multiplier: 1 / 1.6).isActive = true
        recorder.onChange = { [weak self] in
            guard let self else { return }
            surface.progress = recorder.progress
            surface.fingers = recorder.fingers
            if recorder.available != shownAvailable ?? nil { refresh() }
            guard recorder.progress != lastProgress else { return }
            lastProgress = recorder.progress
            updateLabels()
            recordEvidence()
        }
    }

    override func activate() {
        recorder.start()
        super.activate()
    }

    override func deactivate() {
        recorder.stop()
    }

    /// At most twice a second: the evidence goes through the checklist and its list.
    private func recordEvidence() {
        guard !evidencePending else { return }
        evidencePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            evidencePending = false
            core.recordCheck(.trackpad, detail: recorder.progress.detail, passed: recorder.progress.complete)
        }
    }

    private func updateLabels() {
        let progress = recorder.progress
        zonesLabel.stringValue = L("Click zones: left %lld / %lld · right %lld / %lld", progress.leftZones.count,
                                   TrackpadProgress.zoneCount, progress.rightZones.count, TrackpadProgress.zoneCount)
        for (label, title, done) in [(forceLabel, L("Force click"), progress.forceClick), (scrollLabel, L("Scroll"), progress.scroll),
                                     (pinchLabel, L("Pinch"), progress.pinch)] {
            label.stringValue = (done ? "✓ " : "○ ") + title
            label.textColor = done ? LegacyStyle.cool : .secondaryLabelColor
        }
        surfaceLabel.stringValue = L("Surface %@ · up to %lld fingers", Format.percent(progress.coverage * 100), progress.maxTouches)
    }

    override func blocks() -> [Block] {
        shownAvailable = recorder.available
        surface.progress = recorder.progress
        updateLabels()
        var blocks: [Block] = []
        if recorder.available == false {
            blocks.append(.status(L("Raw trackpad data is not available on this Mac; only clicks and gestures are checked."), .bad))
        }
        blocks.append(.view(surface))
        blocks.append(.view(hStack([zonesLabel, forceLabel, scrollLabel, pinchLabel, makeSpacer()], spacing: 14)))
        let haptic = ActionButton(title: L("Haptic feedback")) { TrackpadRecorder.pulse() }
        haptic.toolTip = L("Keep a finger resting on the trackpad: three taps should be felt.")
        blocks.append(.view(hStack([surfaceLabel, makeSpacer(), haptic,
                                    ActionButton(title: L("Reset")) { [unowned self] in recorder.reset() }])))
        return blocks
    }
}

/// Touched cells, the 3 × 3 click zones with their left / right marks and the live fingers.
final class TrackpadSurfaceView: NSView {
    var progress = TrackpadProgress() { didSet { if progress != oldValue { needsDisplay = true } } }
    var fingers: [FSTouch] = [] { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        background.fill()
        NSGraphicsContext.saveGraphicsState()
        background.addClip()
        let w = bounds.width / CGFloat(TrackpadProgress.columns)
        let h = bounds.height / CGFloat(TrackpadProgress.rows)
        LegacyStyle.cool.withAlphaComponent(0.45).setFill()
        for cell in progress.cells {
            NSRect(x: CGFloat(cell % TrackpadProgress.columns) * w, y: CGFloat(cell / TrackpadProgress.columns) * h,
                   width: w, height: h).insetBy(dx: 1, dy: 1).fill()
        }
        let grid = NSBezierPath()
        for c in 1..<TrackpadProgress.columns {
            grid.move(to: NSPoint(x: CGFloat(c) * w, y: 0))
            grid.line(to: NSPoint(x: CGFloat(c) * w, y: bounds.height))
        }
        for r in 1..<TrackpadProgress.rows {
            grid.move(to: NSPoint(x: 0, y: CGFloat(r) * h))
            grid.line(to: NSPoint(x: bounds.width, y: CGFloat(r) * h))
        }
        grid.lineWidth = 0.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.15).setStroke()
        grid.stroke()

        let zw = bounds.width / CGFloat(TrackpadProgress.zoneColumns)
        let zh = bounds.height / CGFloat(TrackpadProgress.zoneRows)
        let zones = NSBezierPath()
        for c in 1..<TrackpadProgress.zoneColumns {
            zones.move(to: NSPoint(x: CGFloat(c) * zw, y: 0))
            zones.line(to: NSPoint(x: CGFloat(c) * zw, y: bounds.height))
        }
        for r in 1..<TrackpadProgress.zoneRows {
            zones.move(to: NSPoint(x: 0, y: CGFloat(r) * zh))
            zones.line(to: NSPoint(x: bounds.width, y: CGFloat(r) * zh))
        }
        zones.lineWidth = 1.5
        zones.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.secondaryLabelColor.withAlphaComponent(0.6).setStroke()
        zones.stroke()
        for zone in 0..<TrackpadProgress.zoneCount {
            let center = NSPoint(x: (CGFloat(zone % TrackpadProgress.zoneColumns) + 0.5) * zw,
                                 y: (CGFloat(zone / TrackpadProgress.zoneColumns) + 0.5) * zh)
            badge(L("Left"), at: NSPoint(x: center.x - 30, y: center.y), done: progress.leftZones.contains(zone))
            badge(L("Right"), at: NSPoint(x: center.x + 30, y: center.y), done: progress.rightZones.contains(zone))
        }
        LegacyStyle.warm(in: self).withAlphaComponent(0.9).setFill()
        for finger in fingers {
            let p = NSPoint(x: CGFloat(finger.x) * bounds.width, y: (1 - CGFloat(finger.y)) * bounds.height)
            NSBezierPath(ovalIn: NSRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.labelColor.withAlphaComponent(0.2).setStroke()
        background.stroke()
    }

    private func badge(_ text: String, at point: NSPoint, done: Bool) {
        let rect = NSRect(x: point.x - 26, y: point.y - 11, width: 52, height: 22)
        (done ? LegacyStyle.cool : NSColor.secondaryLabelColor.withAlphaComponent(0.2)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 11, yRadius: 11).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: LegacyStyle.caption, weight: .semibold),
            .foregroundColor: done ? NSColor.white : NSColor.secondaryLabelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), withAttributes: attributes)
    }
}
