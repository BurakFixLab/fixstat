import AppKit
import MacSensors

/// Touch Bar test: the whole bar is split into cells that turn green where it registers a
/// touch (a dead zone stays grey), and solid colours show dead or stuck pixels.
///
/// The bar is shown "system modal" (the private class methods MTMR and similar tools use)
/// so it covers the full width, Control Strip and Esc area included; without them it falls
/// back to the key window's Touch Bar. Main thread; `onChange` after every change.
public final class TouchBarTester: NSObject, NSTouchBarDelegate {
    public enum Mode: Equatable {
        case off
        case touch
        case colour(Int)
    }

    /// Colours of the display test, in order.
    public static let colours: [NSColor] = [.black, .white, .red, .green, .blue]
    public static let cellCount = 32
    /// Part of the cells kept in the Esc area (its own item, left of the main one).
    static let escapeCells = 2

    public private(set) var mode = Mode.off
    public private(set) var touched = Set<Int>()
    /// True when the system-modal presentation was available.
    public private(set) var fullWidth = false
    public var onChange: (() -> Void)?

    private var bar: NSTouchBar?
    private let escapeView = TouchBarCanvas(first: 0, count: TouchBarTester.escapeCells)
    private let mainView = TouchBarCanvas(first: TouchBarTester.escapeCells,
                                          count: TouchBarTester.cellCount - TouchBarTester.escapeCells)
    private static let escapeID = NSTouchBarItem.Identifier("io.github.burakfixlab.fixstat.touchbar.escape")
    private static let mainID = NSTouchBarItem.Identifier("io.github.burakfixlab.fixstat.touchbar.main")

    public override init() {
        super.init()
        for view in [escapeView, mainView] {
            view.onTouch = { [weak self] cell in self?.touch(cell) }
        }
    }

    public var allTouched: Bool { touched.count == Self.cellCount }

    public func startTouchTest() {
        touched = []
        show(.touch)
    }

    public func showColour(_ index: Int) {
        show(.colour(index % Self.colours.count))
    }

    public func stop() {
        guard mode != .off else { return }
        mode = .off
        dismiss()
        onChange?()
    }

    private func touch(_ cell: Int) {
        guard mode == .touch, touched.insert(cell).inserted else { return }
        redraw()
        onChange?()
    }

    private func show(_ mode: Mode) {
        self.mode = mode
        redraw()
        if bar == nil { present() }
        onChange?()
    }

    private func redraw() {
        for view in [escapeView, mainView] {
            view.touched = touched
            if case let .colour(index) = mode { view.colour = Self.colours[index] } else { view.colour = nil }
            view.needsDisplay = true
        }
    }

    // MARK: Presentation

    private func present() {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [Self.mainID]
        bar.escapeKeyReplacementItemIdentifier = Self.escapeID
        self.bar = bar
        let modern = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        let older = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")
        let cls: AnyObject = NSTouchBar.self
        if cls.responds(to: modern) {
            _ = cls.perform(modern, with: bar, with: nil)
            fullWidth = true
        } else if cls.responds(to: older) {
            _ = cls.perform(older, with: bar, with: nil)
            fullWidth = true
        } else {
            fullWidth = false
            NSApp.keyWindow?.touchBar = bar
        }
    }

    private func dismiss() {
        guard let bar else { return }
        let modern = NSSelectorFromString("dismissSystemModalTouchBar:")
        let older = NSSelectorFromString("dismissSystemModalFunctionBar:")
        let cls: AnyObject = NSTouchBar.self
        if cls.responds(to: modern) {
            _ = cls.perform(modern, with: bar)
        } else if cls.responds(to: older) {
            _ = cls.perform(older, with: bar)
        } else if NSApp.keyWindow?.touchBar === bar {
            NSApp.keyWindow?.touchBar = nil
        }
        self.bar = nil
    }

    public func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        let item = NSCustomTouchBarItem(identifier: identifier)
        let view = identifier == Self.escapeID ? escapeView : mainView
        view.translatesAutoresizingMaskIntoConstraints = false
        // Wider than the bar: AppKit shrinks the main item to the space left.
        let width: CGFloat = identifier == Self.escapeID ? 64 : 1_100
        let constraint = view.widthAnchor.constraint(equalToConstant: width)
        constraint.priority = .defaultLow
        constraint.isActive = true
        item.view = view
        return item
    }
}

/// One part of the Touch Bar: draws its cells (or a solid colour) and reports touched cells.
final class TouchBarCanvas: NSView {
    let first: Int
    let count: Int
    var touched = Set<Int>()
    var colour: NSColor?
    var onTouch: ((Int) -> Void)?

    init(first: Int, count: Int) {
        self.first = first
        self.count = count
        super.init(frame: .zero)
        allowedTouchTypes = [.direct]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if let colour {
            colour.setFill()
            bounds.fill()
            return
        }
        let width = bounds.width / CGFloat(count)
        for index in 0..<count {
            let cell = NSRect(x: CGFloat(index) * width + 1, y: 1, width: width - 2, height: bounds.height - 2)
            (touched.contains(first + index) ? NSColor.systemGreen : NSColor(white: 0.25, alpha: 1)).setFill()
            NSBezierPath(roundedRect: cell, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func report(_ event: NSEvent) {
        for touch in event.touches(matching: [.began, .moved], in: self) where touch.type == .direct {
            let x = touch.location(in: self).x
            guard bounds.width > 0, x >= 0, x < bounds.width else { continue }
            onTouch?(first + Int(x / bounds.width * CGFloat(count)))
        }
    }

    override func touchesBegan(with event: NSEvent) { report(event) }
    override func touchesMoved(with event: NSEvent) { report(event) }
}

/// Texts of the Touch Bar test (both interfaces).
public enum TouchBarText {
    public static func progress(_ tester: TouchBarTester) -> String {
        L("%lld / %lld zones touched", tester.touched.count, TouchBarTester.cellCount)
    }

    public static func colourName(_ index: Int) -> String {
        [L("Black"), L("White"), L("Red"), L("Green"), L("Blue")][index % 5]
    }
}
