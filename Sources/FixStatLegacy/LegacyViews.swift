import AppKit
import MacSensors
import FixStatCore

// Small AppKit building blocks for the legacy interface (macOS 10.13+), mirroring the
// SwiftUI ones in Theme.swift.

enum LegacyStyle {
    static let panelWidth: CGFloat = 360
    static let padding: CGFloat = 14

    static var accent: NSColor {
        if #available(macOS 10.14, *) { return .controlAccentColor }
        return .systemBlue
    }

    /// Faint fill for tiles and bar tracks.
    static var fill: NSColor {
        NSColor.labelColor.withAlphaComponent(0.08)
    }

    static func isDark(_ view: NSView?) -> Bool {
        if #available(macOS 10.14, *) {
            let appearance = view?.effectiveAppearance ?? NSApp.effectiveAppearance
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return false
    }

    /// Temperature colours: blue / amber / orange (no red–green split).
    static func temperatureColor(_ celsius: Double?, in view: NSView?) -> NSColor {
        guard let celsius else { return .secondaryLabelColor }
        let defaults = UserDefaults.standard
        if celsius >= defaults.double(forKey: Pref.hotThreshold) { return hot }
        if celsius >= defaults.double(forKey: Pref.warmThreshold) { return warm(in: view) }
        return cool
    }

    static let cool = NSColor.systemBlue
    static let hot = NSColor.systemOrange

    static func warm(in view: NSView?) -> NSColor {
        isDark(view)
            ? NSColor(srgbRed: 0.90, green: 0.68, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.52, blue: 0.10, alpha: 1)
    }

    static func digits(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    static func mono(_ size: CGFloat) -> NSFont {
        if #available(macOS 10.15, *) { return NSFont.monospacedSystemFont(ofSize: size, weight: .regular) }
        return NSFont(name: "Menlo", size: size) ?? NSFont.userFixedPitchFont(ofSize: size) ?? .systemFont(ofSize: size)
    }

    static let body: CGFloat = 12
    static let caption: CGFloat = 10
}

func makeLabel(_ text: String, size: CGFloat = LegacyStyle.body, weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor, font: NSFont? = nil) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font ?? LegacyStyle.digits(size, weight: weight)
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

/// Wrapping, secondary text.
func makeNote(_ text: String, width: CGFloat) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: LegacyStyle.caption)
    label.textColor = .secondaryLabelColor
    label.preferredMaxLayoutWidth = width
    return label
}

/// "BATTERY" style section title.
func makeSectionTitle(_ text: String) -> NSTextField {
    makeLabel(text.uppercased(with: .current), size: LegacyStyle.caption, weight: .semibold, color: .secondaryLabelColor)
}

func hStack(_ views: [NSView], spacing: CGFloat = 8, alignment: NSLayoutConstraint.Attribute = .centerY) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.spacing = spacing
    stack.alignment = alignment
    stack.distribution = .fill
    return stack
}

func vStack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = spacing
    // Keep the content together instead of spreading it over extra height.
    stack.setHuggingPriority(.defaultHigh, for: .vertical)
    return stack
}

/// Flexible space for horizontal stacks.
func makeSpacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return view
}

func makeSeparator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    return box
}

/// A button that calls a closure.
final class ActionButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(title: String, style: NSButton.BezelStyle = .rounded, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        bezelStyle = style
        self.handler = handler
        target = self
        action = #selector(run)
    }

    /// Borderless accent-coloured text button ("Details", "All (50)").
    static func link(_ title: String, handler: @escaping () -> Void) -> ActionButton {
        let button = ActionButton(title: title, handler: handler)
        button.isBordered = false
        button.setLinkTitle(title)
        return button
    }

    func setLinkTitle(_ title: String) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: LegacyStyle.accent,
            .font: LegacyStyle.digits(LegacyStyle.caption),
        ])
    }

    @objc private func run() { handler?() }
}

/// Thin horizontal bar (0…1).
final class LevelBar: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }
    var color: NSColor = LegacyStyle.cool { didSet { needsDisplay = true } }
    private let height: CGFloat

    init(height: CGFloat = 4, width: CGFloat? = nil) {
        self.height = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        if let width { widthAnchor.constraint(equalToConstant: width).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let radius = height / 2
        LegacyStyle.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let width = max(height, bounds.width * CGFloat(min(max(fraction, 0), 1)))
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

/// Rounded background behind a content view.
final class TileView: NSView {
    var fillColor: NSColor = LegacyStyle.fill { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 6

    init(content: NSView, horizontal: CGFloat = 8, vertical: CGFloat = 6) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontal),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontal),
            content.topAnchor.constraint(equalTo: topAnchor, constant: vertical),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -vertical),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
}

/// Small filled circle (sensor colour dot).
final class DotView: NSView {
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }

    init(size: CGFloat = 7) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

/// Flipped document view so scroll views start at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Status item battery icon: an SF Symbol on macOS 11+, drawn by hand before that.
enum BatteryIcon {
    static func image(for battery: BatteryInfo?) -> NSImage? {
        if #available(macOS 11.0, *) {
            let image = NSImage(systemSymbolName: BatteryText.symbol(battery), accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        }
        return drawn(level: (battery?.stateOfCharge ?? 0) / 100,
                     charging: battery?.isCharging == true || battery?.fullyCharged == true)
    }

    private static func drawn(level: Double, charging: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 24, height: 12), flipped: false) { _ in
            NSColor.black.set()
            let body = NSRect(x: 1, y: 1.5, width: 19, height: 9)
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: 20.5, y: 4.5, width: 1.8, height: 3), xRadius: 0.8, yRadius: 0.8).fill()
            let inner = body.insetBy(dx: 1.8, dy: 1.8)
            let width = inner.width * CGFloat(min(max(level, 0), 1))
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: max(width, 1), height: inner.height),
                         xRadius: 1, yRadius: 1).fill()
            if charging {
                // Bolt cut out of the fill.
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 11.5, y: 11))
                bolt.line(to: NSPoint(x: 7.5, y: 5.5))
                bolt.line(to: NSPoint(x: 10.3, y: 5.5))
                bolt.line(to: NSPoint(x: 9.5, y: 1))
                bolt.line(to: NSPoint(x: 13.5, y: 6.5))
                bolt.line(to: NSPoint(x: 10.7, y: 6.5))
                bolt.close()
                bolt.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
