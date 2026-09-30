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
