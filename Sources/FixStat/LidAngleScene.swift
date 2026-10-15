import SwiftUI
import FixStatCore
import MacSensors

/// The lid test's live picture: this Mac seen from the side, its lid at the angle the hinge
/// sensor reports. Every display frame reads the newest angle and eases towards it, so the
/// drawing moves with the lid instead of jumping from reading to reading.
@available(macOS 14.0, *)
struct LidAngleScene: View {
    /// The newest angle (degrees, 0 = closed), read once per display frame.
    let angle: () -> Double?
    @State private var follower = AngleFollower()
    @State private var notebook = NotebookSideScene.Body.current()
    @State private var finish = HousingColor.current()

    var body: some View {
        TimelineView(.animation) { context in
            let shown = follower.value(at: context.date, target: angle())
            NotebookSideModel(angle: shown ?? 110, notebook: notebook, finish: finish)
                .frame(width: 580, height: 300)
                .overlay(alignment: .topTrailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: shown.map { LidText.angle($0.rounded()) } ?? "–")
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: shown ?? 0))
                        Text("Lid angle").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(8)
                }
        }
    }
}

/// Draws `NotebookSideScene` (this Mac's body from the side) for one lid angle.
@available(macOS 14.0, *)
struct NotebookSideModel: View {
    let angle: Double
    let notebook: NotebookSideScene.Body
    let finish: HousingColor?

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                NotebookSideScene(size: size, body: notebook, finish: finish).draw(in: cg, angle: angle)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: LidText.angle(angle.rounded())))
    }
}
