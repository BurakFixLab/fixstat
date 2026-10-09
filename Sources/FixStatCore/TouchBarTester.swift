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
    /// Cells in the Esc area of the bar (its own item, left of the main one) on models whose
    /// Esc key is on the Touch Bar; models with a physical Esc have no such area.
    let escapeCells: Int

    public private(set) var mode = Mode.off
    public private(set) var touched = Set<Int>()
    /// True when the system-modal presentation was available.
    public private(set) var fullWidth = false
    public var onChange: (() -> Void)?

    private var bar: NSTouchBar?
    private let escapeView: TouchBarCanvas
    private let mainView: TouchBarCanvas
    private static let escapeID = NSTouchBarItem.Identifier("io.github.burakfixlab.fixstat.touchbar.escape")
    private static let mainID = NSTouchBarItem.Identifier("io.github.burakfixlab.fixstat.touchbar.main")

    public override init() {
        let defaults = UserDefaults.standard.string(forKey: "FixStatTouchBar").flatMap(HardwareProfile.TouchBar.init(rawValue:))
        let kind = defaults ?? HardwareProfile.touchBar(model: SystemInfo.current().model)
        escapeCells = kind == .withoutEscapeKey ? 2 : 0
        escapeView = TouchBarCanvas(first: 0, count: max(escapeCells, 1))
        mainView = TouchBarCanvas(first: escapeCells, count: Self.cellCount - escapeCells)
        super.init()
        for view in [escapeView, mainView] {
            view.onTouch = { [weak self] cell in self?.touch(cell) }
        }
    }

    public var allTouched: Bool { touched.count == Self.cellCount }

    /// Width of the bar the test can use (Esc area + visible main part), in points; 0 before the
    /// bar is shown. Shown in the pane so a cut-off end can be told from a dead zone.
    public var shownWidth: CGFloat {
        guard bar != nil else { return 0 }
        return (escapeCells > 0 ? escapeView.shownWidth : 0) + mainView.shownWidth
    }

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
        if escapeCells > 0 { bar.escapeKeyReplacementItemIdentifier = Self.escapeID }
        self.bar = bar
        // No close box at the left end of the system-modal bar (it would cover the first cells).
        if let handle = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY),
           let symbol = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
            typealias ShowsCloseBox = @convention(c) (Bool) -> Void
            unsafeBitCast(symbol, to: ShowsCloseBox.self)(false)
        }
        // Placement 1 covers the whole bar, Control Strip (brightness, volume, Siri) included.
        typealias PresentWithPlacement = @convention(c) (AnyObject, Selector, NSTouchBar, Int, AnyObject?) -> Void
        let cls: AnyObject = NSTouchBar.self
        for name in ["presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
                     "presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:"] {
            let selector = NSSelectorFromString(name)
            guard cls.responds(to: selector), let method = class_getClassMethod(NSTouchBar.self, selector) else { continue }
            let present = unsafeBitCast(method_getImplementation(method), to: PresentWithPlacement.self)
            present(cls, selector, bar, 1, nil)
            fullWidth = true
            return
        }
        let modern = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        let older = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")
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

    /// The part of the view the bar shows. The main item asks for more width than any Touch Bar
    /// has; when AppKit does not shrink it (MacBookPro15,2: Esc area 64 pt + 1 100 pt on a
    /// ≈ 1 085 pt bar), the right end is cut off, so the cells are spread over what is visible.
    var shownWidth: CGFloat {
        let visible = visibleRect
        return visible.width > 0 ? min(bounds.width, visible.maxX) : bounds.width
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let colour {
            colour.setFill()
            bounds.fill()
            return
        }
        let width = shownWidth / CGFloat(count)
        for index in 0..<count {
            let cell = NSRect(x: CGFloat(index) * width + 1, y: 1, width: width - 2, height: bounds.height - 2)
            (touched.contains(first + index) ? NSColor.systemGreen : NSColor(white: 0.25, alpha: 1)).setFill()
            NSBezierPath(roundedRect: cell, xRadius: 3, yRadius: 3).fill()
        }
    }

    private func report(_ event: NSEvent) {
        for touch in event.touches(matching: [.began, .moved], in: self) where touch.type == .direct {
            let x = touch.location(in: self).x
            let width = shownWidth
            guard width > 0, x >= 0, x < width else { continue }
            onTouch?(first + Int(x / width * CGFloat(count)))
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

    /// "Touch Bar width used: 1 085 pt" while the bar is shown, for telling a cut-off end from
    /// a dead zone.
    public static func width(_ tester: TouchBarTester) -> String? {
        let width = tester.shownWidth
        return width > 0 ? L("Touch Bar width used: %@ pt", Format.number(Double(width))) : nil
    }

    public static func colourName(_ index: Int) -> String {
        [L("Black"), L("White"), L("Red"), L("Green"), L("Blue")][index % 5]
    }
}
