import SwiftUI
import FixStatCore

/// The lid test's live picture: a notebook seen from the front and a little above, its lid at
/// the angle the hinge sensor reports. Every display frame reads the newest angle and eases
/// towards it, so the drawing moves with the lid instead of jumping ten times a second.
@available(macOS 14.0, *)
struct LidAngleScene: View {
    /// The newest angle (degrees, 0 = closed), read once per display frame.
    let angle: () -> Double?
    @State private var follower = AngleFollower()
    @State private var notebook = NotebookSideScene.Body.current()

    var body: some View {
        TimelineView(.animation) { context in
            let shown = follower.value(at: context.date, target: angle())
            // Two pictures for now, so the owner can pick one at the bench: 3D from the front, and
            // the side profile of this Mac's body.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 16) {
                    NotebookModel(angle: shown ?? 110, hasReading: shown != nil)
                        .frame(width: 250, height: 190)
                    NotebookSideModel(angle: shown ?? 110, hasReading: shown != nil, notebook: notebook)
                        .frame(width: 320, height: 190)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(verbatim: shown.map { LidText.angle($0.rounded()) } ?? "–")
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: shown ?? 0))
                    Text("Lid angle").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Eases the shown angle towards the sensor's (critically damped, ~60 ms), so integer steps and
/// the gaps between sensor reports do not show.
@available(macOS 14.0, *)
final class AngleFollower {
    private var shown: Double?
    private var last: Date?

    func value(at date: Date, target: Double?) -> Double? {
        guard let target else { return shown }
        defer { last = date }
        guard let current = shown, let last else {
            shown = target
            return target
        }
        let elapsed = min(max(date.timeIntervalSince(last), 0), 0.1)
        let next = current + (target - current) * (1 - exp(-elapsed / 0.06))
        shown = abs(next - target) < 0.05 ? target : next
        return shown
    }
}

/// Draws `NotebookScene` (the core's 3D notebook) for one lid angle.
@available(macOS 14.0, *)
struct NotebookModel: View {
    let angle: Double
    let hasReading: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShapeCanvas(label: LidText.angle(angle.rounded())) { size in
            NotebookScene(size: size, dark: colorScheme == .dark).shapes(angle: angle, hasReading: hasReading)
        }
    }
}

/// Draws `NotebookSideScene` (this Mac's body from the side) for one lid angle.
@available(macOS 14.0, *)
struct NotebookSideModel: View {
    let angle: Double
    let hasReading: Bool
    let notebook: NotebookSideScene.Body

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ShapeCanvas(label: LidText.angle(angle.rounded())) { size in
            NotebookSideScene(size: size, body: notebook, dark: colorScheme == .dark)
                .shapes(angle: angle, hasReading: hasReading, accent: Self.accent)
        }
    }

    static var accent: NotebookScene.RGBA {
        let colour = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return NotebookScene.RGBA(Double(colour.redComponent), Double(colour.greenComponent), Double(colour.blueComponent))
    }
}

/// Fills the core's scene polygons.
@available(macOS 14.0, *)
struct ShapeCanvas: View {
    let label: String
    let shapes: (CGSize) -> [NotebookScene.Shape]

    var body: some View {
        Canvas { context, size in
            for shape in shapes(size) {
                var path = Path()
                path.addLines(shape.points)
                path.closeSubpath()
                switch shape.fill {
                case let .solid(colour):
                    context.fill(path, with: .color(Self.color(colour)))
                case let .gradient(colours, start, end):
                    context.fill(path, with: .linearGradient(Gradient(colors: colours.map(Self.color)),
                                                             startPoint: start, endPoint: end))
                case let .shadow(colour, radius):
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: radius))
                        layer.fill(path, with: .color(Self.color(colour)))
                    }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: label))
    }

    static func color(_ c: NotebookScene.RGBA) -> Color {
        Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
