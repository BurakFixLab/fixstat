import AppKit
import SwiftUI
import FixStatCore

/// Temperature colours. Deliberately blue / amber / orange (no red–green split).
@available(macOS 14.0, *)
enum TemperatureColor {
    static let cool = Color(nsColor: .systemBlue)
    static let warm = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.90, green: 0.68, blue: 0.24, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.52, blue: 0.10, alpha: 1)
    })
    static let hot = Color(nsColor: .systemOrange)

    static func color(for celsius: Double?, warm: Double, hot: Double) -> Color {
        guard let celsius else { return .secondary }
        if celsius >= hot { return self.hot }
        if celsius >= warm { return self.warm }
        return cool
    }
}

/// Section title in small caps style, e.g. "BATTERY".
@available(macOS 14.0, *)
struct SectionTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .textCase(.uppercase)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Thin horizontal bar.
@available(macOS 14.0, *)
struct LevelBar: View {
    /// 0…1
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color)
                    .frame(width: max(height, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A small rounded tile with a caption and a value.
@available(macOS 14.0, *)
struct Tile: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

@available(macOS 14.0, *)
extension Double {
    /// Maps a temperature onto a bar fraction (20 °C → 0, 100 °C → 1).
    var temperatureFraction: Double { (self - 20) / 80 }
}

// MARK: - Cards (2026-10 design: one soft card per topic)

/// Shared spacing and shapes of the card layout.
@available(macOS 14.0, *)
enum Design {
    /// Corner radius of a card.
    static let cardRadius: CGFloat = 10
    /// Space between cards.
    static let cardSpacing: CGFloat = 8
    /// Padding inside a card.
    static let cardPadding = EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 12)
    /// Space between rows inside a card.
    static let rowSpacing: CGFloat = 5
}

/// A topic of the panel or a window: a softly filled, rounded box.
@available(macOS 14.0, *)
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Design.rowSpacing) { content }
            .padding(Design.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Design.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Design.cardRadius).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
    }
}

/// Card title with an icon, and optional text or a control on the right.
@available(macOS 14.0, *)
struct CardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    @ViewBuilder let trailing: Trailing

    init(_ title: LocalizedStringKey, systemImage: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
                .font(.callout)
        }
        .padding(.bottom, 2)
    }
}

/// Label on the left (secondary), value right-aligned.
@available(macOS 14.0, *)
struct CardRow: View {
    let title: Text
    let value: String?
    var valueStyle: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            title.foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 8)
            Text(value ?? "–")
                .monospacedDigit()
                .foregroundStyle(valueStyle ?? .primary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Status of a reading: normal, attention, problem. Colour plus a shape, so it does not
/// rely on colour alone.
@available(macOS 14.0, *)
struct StatusDot: View {
    let color: Color
    var level = 0

    var body: some View {
        Image(systemName: level >= 2 ? "exclamationmark.triangle.fill" : "circle.fill")
            .font(.system(size: level >= 2 ? 9 : 7))
            .foregroundStyle(color)
            .frame(width: 12)
            .accessibilityHidden(true)
    }
}

/// A large number with a small label above it (window summaries).
@available(macOS 14.0, *)
struct MetricTile: View {
    let title: Text
    let value: String
    var unit: String? = nil

    init(title: LocalizedStringKey, value: String, unit: String? = nil) {
        self.title = Text(title)
        self.value = value
        self.unit = unit
    }

    /// A title that is already localized (core texts).
    init(verbatim title: String, value: String, unit: String? = nil) {
        self.title = Text(verbatim: title)
        self.value = value
        self.unit = unit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title2.weight(.medium)).monospacedDigit()
                if let unit { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.fill.quinary, in: RoundedRectangle(cornerRadius: Design.cardRadius))
        .accessibilityElement(children: .combine)
    }
}

/// A finding: warning icon, text; rows of a card separated by hairlines.
@available(macOS 14.0, *)
struct FindingRow: View {
    let text: String
    var problem = true

    var body: some View {
        Label {
            Text(verbatim: text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: problem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(problem ? TemperatureColor.hot : TemperatureColor.cool)
        }
    }
}
