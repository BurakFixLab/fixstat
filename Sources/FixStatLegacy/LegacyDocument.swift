import AppKit
import MacSensors
import FixStatCore

// Tool windows of the AppKit interface are described as a list of blocks (titles, rows,
// tables, findings, buttons) and rendered by `LegacyDocumentView`. The same content as
// the SwiftUI tool windows, laid out as a simple scrolling document.

enum Tone {
    case good, bad, neutral

    var color: NSColor {
        switch self {
        case .good: return LegacyStyle.cool
        case .bad: return LegacyStyle.hot
        case .neutral: return .secondaryLabelColor
        }
    }

    /// Text icon (SF Symbols need macOS 11).
    var symbol: String {
        switch self {
        case .good: return "✓"
        case .bad: return "⚠︎"
        case .neutral: return "ⓘ"
        }
    }
}

struct DocRow {
    var title: String
    var value: String?
    var tone: Tone? = nil
}

struct DocAction {
    var title: String
    var link = false
    var handler: () -> Void
}

indirect enum Block {
    /// Large window title and optional secondary lines under it.
    case header(String, [String])
    /// "BATTERY" style section title.
    case section(String)
    case text(String)
    case secondary(String)
    case caption(String)
    case headline(String, Tone?)
    /// Selectable monospaced text (panic logs).
    case mono(String)
    /// Icon + text in the tone's colour, with an optional detail line under the text.
    case status(String, Tone, detail: String? = nil)
    /// Text with a secondary detail line under it.
    case item(String, detail: String?)
    /// Blocks close together (a list of findings).
    case list([Block])
    /// Label / value rows; `labelWidth` aligns values in a column, nil spreads them.
    case rows([DocRow], labelWidth: CGFloat?)
    /// Table; column 0 leading, the others trailing unless `leading`.
    case table(header: [String]?, rows: [[String]], tones: [[Tone?]], leading: Bool)
    case tiles([(String, String)], columns: Int)
    /// Rounded box with an optional section title above it.
    case group(String?, [Block])
    case columns([[Block]])
    case actions([DocAction])
    case progress(String)
    /// A view kept by the window's owner (charts, controls); full width.
    case view(NSView)
    case gap
}

/// Scrolling document that renders blocks at a fixed content width.
final class LegacyDocumentView: NSScrollView {
    private let stack = NSStackView()
    private let contentWidth: CGFloat
    private static let padding: CGFloat = 20

    init(contentWidth: CGFloat, padding: CGFloat = LegacyDocumentView.padding) {
        self.contentWidth = contentWidth
        super.init(frame: .zero)
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        documentView = document
        hasVerticalScroller = true
        drawsBackground = false
        let p = padding
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: p),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: p),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -p),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
            document.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func width(forContent content: CGFloat) -> CGFloat { content + 2 * padding + 16 }

    /// Replaces the content, keeping the scroll position.
    func show(_ blocks: [Block]) {
        let origin = contentView.bounds.origin
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for block in blocks {
            add(render(block, width: contentWidth), to: stack, width: contentWidth)
        }
        documentView?.layoutSubtreeIfNeeded()
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func add(_ view: NSView, to stack: NSStackView, width: CGFloat) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    // MARK: Rendering

    private func render(_ block: Block, width: CGFloat) -> NSView {
        switch block {
        case let .header(title, lines):
            var views: [NSView] = [makeLabel(title, font: .systemFont(ofSize: 17, weight: .semibold))]
            views += lines.map { wrapping($0, width: width, color: .secondaryLabelColor) }
            return vStack(views, spacing: 4)
        case let .section(title):
            return makeSectionTitle(title)
        case let .text(text):
            return wrapping(text, width: width)
        case let .secondary(text):
            return wrapping(text, width: width, color: .secondaryLabelColor)
        case let .caption(text):
            return wrapping(text, width: width, size: LegacyStyle.caption, color: .secondaryLabelColor)
        case let .headline(text, tone):
            let label = wrapping((tone.map { $0.symbol + " " } ?? "") + text, width: width,
                                 font: .systemFont(ofSize: 13, weight: .semibold))
            if let tone { label.textColor = tone.color }
            return label
        case let .mono(text):
            let label = wrapping(text, width: width - 16, font: LegacyStyle.mono(10))
            label.isSelectable = true
            let tile = TileView(content: label, horizontal: 8, vertical: 8)
            return tile
        case let .status(text, tone, detail):
            let icon = makeLabel(tone.symbol, color: tone.color)
            icon.setContentCompressionResistancePriority(.required, for: .horizontal)
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            var lines: [NSView] = [wrapping(text, width: width - 24, color: tone == .bad ? tone.color : .labelColor)]
            if let detail {
                lines.append(wrapping(detail, width: width - 24, color: .secondaryLabelColor, font: LegacyStyle.mono(LegacyStyle.caption)))
            }
            return hStack([icon, vStack(lines, spacing: 1)], spacing: 6, alignment: .firstBaseline)
        case let .item(text, detail):
            var lines: [NSView] = [wrapping(text, width: width)]
            if let detail {
                lines.append(wrapping(detail, width: width, size: LegacyStyle.caption, color: .secondaryLabelColor))
            }
            return vStack(lines, spacing: 1)
        case let .list(blocks):
            let list = NSStackView()
            list.orientation = .vertical
            list.alignment = .leading
            list.spacing = 5
            list.setHuggingPriority(.defaultHigh, for: .vertical)
            for block in blocks {
                add(render(block, width: width), to: list, width: width)
            }
            return list
        case let .rows(rows, labelWidth):
            return renderRows(rows, labelWidth: labelWidth, width: width)
        case let .table(header, rows, tones, leading):
            // Natural column widths, not stretched to the document width.
            return hStack([renderTable(header: header, rows: rows, tones: tones, leading: leading), makeSpacer()],
                          alignment: .top)
        case let .tiles(items, columns):
            return renderTiles(items, columns: columns, width: width)
        case let .group(title, blocks):
            let inner = NSStackView()
            inner.orientation = .vertical
            inner.alignment = .leading
            inner.spacing = 6
            inner.setHuggingPriority(.defaultHigh, for: .vertical)
            let innerWidth = width - 20
            for block in blocks {
                add(render(block, width: innerWidth), to: inner, width: innerWidth)
            }
            let box = TileView(content: inner, horizontal: 10, vertical: 10)
            box.cornerRadius = 8
            guard let title else { return box }
            let column = vStack([makeSectionTitle(title), box], spacing: 6)
            box.widthAnchor.constraint(equalToConstant: width).isActive = true
            return column
        case let .columns(columns):
            let spacing: CGFloat = 18
            let columnWidth = (width - spacing * CGFloat(columns.count - 1)) / CGFloat(max(columns.count, 1))
            let views = columns.map { blocks -> NSView in
                let column = NSStackView()
                column.orientation = .vertical
                column.alignment = .leading
                column.spacing = 8
                column.setHuggingPriority(.defaultHigh, for: .vertical)
                for block in blocks {
                    add(render(block, width: columnWidth), to: column, width: columnWidth)
                }
                column.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
                return column
            }
            return hStack(views, spacing: spacing, alignment: .top)
        case let .actions(actions):
            var views: [NSView] = actions.map { action in
                action.link ? ActionButton.link(action.title, handler: action.handler)
                    : ActionButton(title: action.title, handler: action.handler)
            }
            views.append(makeSpacer())
            return hStack(views)
        case let .progress(text):
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            return hStack([spinner, makeLabel(text, color: .secondaryLabelColor), makeSpacer()])
        case let .view(view):
            return view
        case .gap:
            let view = NSView()
            view.heightAnchor.constraint(equalToConstant: 2).isActive = true
            return view
        }
    }

    private func wrapping(_ text: String, width: CGFloat, size: CGFloat = LegacyStyle.body,
                          color: NSColor = .labelColor, font: NSFont? = nil) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font ?? LegacyStyle.digits(size)
        label.textColor = color
        label.preferredMaxLayoutWidth = width
        label.isSelectable = false
        return label
    }

    private func renderRows(_ rows: [DocRow], labelWidth: CGFloat?, width: CGFloat) -> NSView {
        let views = rows.map { row -> NSView in
            let title = makeLabel(row.title, color: .secondaryLabelColor)
            let valueWidth = labelWidth.map { width - $0 - 8 } ?? width * 0.6
            let value = wrapping(row.value ?? "–", width: valueWidth, color: row.tone == .bad ? LegacyStyle.hot : .labelColor)
            value.isSelectable = true
            if let labelWidth {
                title.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
                return hStack([title, value, makeSpacer()], alignment: .firstBaseline)
            }
            value.alignment = .right
            value.font = LegacyStyle.mono(LegacyStyle.body)
            title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            return hStack([title, makeSpacer(), value], alignment: .firstBaseline)
        }
        let stack = vStack(views, spacing: 5)
        for view in views { view.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return stack
    }

    private func renderTable(header: [String]?, rows: [[String]], tones: [[Tone?]], leading: Bool) -> NSView {
        var cells: [[NSView]] = []
        if let header {
            cells.append(header.map { makeLabel($0, size: LegacyStyle.caption, color: .secondaryLabelColor) })
        }
        for (r, row) in rows.enumerated() {
            cells.append(row.enumerated().map { c, text in
                let tone = r < tones.count && c < tones[r].count ? tones[r][c] : nil
                let label = makeLabel(text, color: tone?.color ?? .labelColor,
                                      font: leading ? nil : LegacyStyle.mono(LegacyStyle.body))
                label.lineBreakMode = .byTruncatingTail
                return label
            })
        }
        let grid = NSGridView(views: cells)
        grid.rowSpacing = 4
        grid.columnSpacing = 16
        grid.rowAlignment = .firstBaseline
        for c in 0..<grid.numberOfColumns {
            grid.column(at: c).xPlacement = c == 0 || leading ? .leading : .trailing
        }
        return grid
    }

    private func renderTiles(_ items: [(String, String)], columns: Int, width: CGFloat) -> NSView {
        let spacing: CGFloat = 8
        let tileWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var lines: [NSView] = []
        for start in stride(from: 0, to: items.count, by: columns) {
            let tiles = items[start..<min(start + columns, items.count)].map { title, value -> NSView in
                let content = vStack([makeLabel(title, size: LegacyStyle.caption, color: .secondaryLabelColor),
                                      makeLabel(value, weight: .semibold)], spacing: 2)
                let tile = TileView(content: content)
                tile.widthAnchor.constraint(equalToConstant: tileWidth).isActive = true
                return tile
            }
            lines.append(hStack(tiles + [makeSpacer()], spacing: spacing))
        }
        return vStack(lines, spacing: spacing)
    }
}

/// A tool window showing a `LegacyDocumentView`; `content` is called on every reload.
final class LegacyToolWindow: NSWindowController, NSWindowDelegate {
    private let documentView: LegacyDocumentView?
    private let content: () -> [Block]
    private var timer: Timer?
    /// Called each time the window is opened (load data, start refreshing).
    var onOpen: (() -> Void)?
    /// Called before every reload (timer ticks included), e.g. to read new data.
    var onReload: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, contentWidth: CGFloat, height: CGFloat, content: @escaping () -> [Block]) {
        self.content = content
        documentView = LegacyDocumentView(contentWidth: contentWidth)
        let width = LegacyDocumentView.width(forContent: contentWidth)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: width, height: 300)
        window.contentMaxSize = NSSize(width: width, height: 10_000)
        window.contentView = documentView
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    /// A window with its own content view instead of blocks.
    init(title: String, view: NSView, size: NSSize) {
        content = { [] }
        documentView = nil
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: size.width, height: 500)
        window.contentView = view
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload() {
        onReload?()
        documentView?.show(content())
    }

    /// Reloads every `interval` seconds while the window is open.
    func refresh(every interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func tick() { reload() }

    func present() {
        onOpen?()
        reload()
        // Not taller than the screen (768 px on an 11" MacBook Air).
        if let window, let visible = (window.screen ?? NSScreen.main)?.visibleFrame, window.frame.height > visible.height {
            var frame = window.frame
            frame.size.height = visible.height
            frame.origin.y = visible.minY
            window.setFrame(frame, display: false)
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        onClose?()
    }
}
