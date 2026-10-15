import Foundation
import CoreGraphics
import MacSensors

/// The lid test's notebook seen from the left side, like Apple's product side shots: this Mac's
/// body (flat or wedge MacBook Air, MacBook Pro) true to scale in millimetres, with its left-side
/// ports and feet, the lid turning about the hinge. Returned as filled polygons, back to front,
/// like `NotebookScene`, so both interfaces draw the same picture. Hinge on the left, front on
/// the right.
public struct NotebookSideScene {
    public typealias RGBA = NotebookScene.RGBA
    public typealias Shape = NotebookScene.Shape
    typealias Fill = NotebookScene.Fill

    /// Body shapes (side profile), from published dimensions.
    public enum Body: String, CaseIterable {
        /// MacBook Air M2 and later: flat, 11.3 mm (13" / 15").
        case air13, air15
        /// MacBook Air before M2: a wedge, 16 mm at the hinge, 4 mm at the front.
        case wedge
        /// MacBook Pro 14" / 16" (2021 and later): MagSafe, feet.
        case pro14, pro16
        /// MacBook Pro 13" / 15" / 16" before 2021 (Intel, M1 / M2 13").
        case proClassic

        /// The body of this Mac: from the product name ("MacBook Air (15-inch, M3, 2024)") and
        /// the model identifier (`MacBookAir…` = before M2, a wedge).
        /// `-FixStatNotebookBody air13|air15|wedge|pro14|pro16|proClassic` overrides it.
        public static func current(system: SystemInfo = .current()) -> Body {
            if let raw = UserDefaults.standard.string(forKey: "FixStatNotebookBody"), let body = Body(rawValue: raw) {
                return body
            }
            return of(marketingName: system.marketingName, model: system.model)
        }

        static func of(marketingName: String?, model: String) -> Body {
            let name = marketingName?.lowercased() ?? ""
            if name.contains("macbook pro") || model.hasPrefix("MacBookPro") {
                if model == "Mac14,7" || (model.hasPrefix("MacBookPro") && !model.hasPrefix("MacBookPro18,")) {
                    return .proClassic
                }
                return name.contains("16-inch") ? .pro16 : .pro14
            }
            if model.hasPrefix("MacBookAir") { return .wedge }
            return name.contains("15-inch") ? .air15 : .air13
        }

        struct Port {
            enum Kind { case magSafe, usbC, headphone }
            var kind: Kind
            /// Distance of the port's start from the back of the base (mm).
            var from: Double
        }

        /// Depth, base thickness at the hinge and at the front, lid thickness, rounding of the
        /// base's bottom edge at the back and the front, feet height (mm), and the left side's ports.
        var spec: (depth: Double, rear: Double, front: Double, lid: Double, backCurve: Double,
                   frontCurve: Double, feet: Double, ports: [Port]) {
            switch self {
            case .air13, .air15:
                return (self == .air13 ? 215 : 237.6, 7.4, 7.4, 3.9, 5.5, 3.0, 1.1,
                        [Port(kind: .magSafe, from: 17.5), Port(kind: .usbC, from: 40), Port(kind: .usbC, from: 54.5)])
            case .wedge:
                return (212, 12.4, 0.6, 3.6, 6.0, 0.5, 0.8, [Port(kind: .usbC, from: 17), Port(kind: .usbC, from: 30)])
            case .pro14, .pro16:
                return (self == .pro14 ? 221.2 : 248.1, self == .pro14 ? 10.4 : 11.4, self == .pro14 ? 10.4 : 11.4,
                        self == .pro14 ? 5.1 : 5.4, 5.5, 4.5, 1.6,
                        [Port(kind: .magSafe, from: 19), Port(kind: .usbC, from: 44), Port(kind: .usbC, from: 58),
                         Port(kind: .headphone, from: 88)])
            case .proClassic:
                return (212.4, 10.6, 10.6, 4.3, 3.0, 2.5, 0.9, [Port(kind: .usbC, from: 22), Port(kind: .usbC, from: 38)])
            }
        }
    }

    let body: Body
    let dark: Bool
    private var scale = 1.0, origin = CGPoint.zero

    /// `size`: the picture's size in points; the model is fitted once for every angle (closed
    /// to 135°; rarely opened further, it may then leave the picture), so it does not move as
    /// the lid turns.
    public init(size: CGSize, body: Body, dark: Bool) {
        self.body = body
        self.dark = dark
        let s = body.spec
        // Room on the left for the lid up to 135° and above the base for the lid upright (rarely
        // opened further, it may then leave the picture).
        let lid = s.depth - 3, reach = lid * 0.71 + s.lid
        let width = reach + s.depth + 2, height = s.feet + 3 + s.rear + lid + s.lid
        scale = min(Double(size.width) * 0.96 / width, Double(size.height) * 0.95 / height)
        origin = CGPoint(x: size.width / 2 - CGFloat((s.depth + 2 - reach) / 2 * scale),
                         y: size.height / 2 + CGFloat((height / 2 - s.feet - 3) * scale))
    }

    /// Millimetres (y up) to points (y down).
    private func point(_ p: (Double, Double)) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.0 * scale), y: origin.y - CGFloat(p.1 * scale))
    }

    /// Part of an ellipse, angles in degrees.
    private func arc(_ c: (Double, Double), _ rx: Double, _ ry: Double, from a: Double, to b: Double, steps: Int = 8) -> [(Double, Double)] {
        (0...steps).map { i in
            let t = (a + (b - a) * Double(i) / Double(steps)) * .pi / 180
            return (c.0 + rx * cos(t), c.1 + ry * sin(t))
        }
    }

    /// A pill (fully rounded rectangle) on the side of the base, centred on `y`.
    private func pill(x: Double, y: Double, length: Double, height: Double) -> [(Double, Double)] {
        let r = height / 2
        return arc((x + length - r, y), r, r, from: -90, to: 90) + arc((x + r, y), r, r, from: 90, to: 270)
    }

    // MARK: Colours (silver aluminium)

    private func metal(_ level: Double) -> RGBA {
        let k = dark ? 0.90 : 1.0
        return RGBA(level * k, (level + 0.005) * k, (level + 0.02) * k)
    }

    private func across(_ colours: [RGBA], _ a: (Double, Double), _ b: (Double, Double)) -> Fill {
        .gradient(colours, point(a), point(b))
    }

    // MARK: Picture

    /// The polygons for this lid angle (degrees, 0 = closed), back to front.
    public func shapes(angle rawAngle: Double) -> [Shape] {
        let angle = min(max(rawAngle, 0), 180)
        let s = body.spec
        var shapes: [Shape] = []
        func add(_ points: [(Double, Double)], _ fill: Fill) { shapes.append(Shape(points: points.map(point), fill: fill)) }

        // Soft contact shadow on the table.
        add([(6, -s.feet - 0.4), (s.depth - 6, -s.feet - 0.4), (s.depth - 12, -s.feet - 2.2), (12, -s.feet - 2.2)],
            .shadow(RGBA(0, 0, 0, dark ? 0.55 : 0.16), CGFloat(2.2 * scale)))

        // Feet: dark rubber below the base, near the back and the front.
        let footLength = 19.0
        for x in [17.5, s.depth - 16 - footLength] {
            let foot = [(x, 0.6), (x + footLength, 0.6), (x + footLength - 1.0, -s.feet), (x + 1.0, -s.feet)]
            add(foot, across([RGBA(0.13, 0.13, 0.14), RGBA(0.27, 0.27, 0.29)], (x, 0.6), (x, -s.feet)))
        }

        // Base: flat (or sloped) top with crisp edges, the bottom edge curving up at both ends.
        let topFront = s.front, topRear = s.rear
        let backCurve = min(s.backCurve, topRear * 0.8), frontCurve = min(s.frontCurve, topFront * 0.9)
        let edge = min(0.8, topFront / 3)
        var base: [(Double, Double)] = []
        base += arc((backCurve, backCurve), backCurve, backCurve, from: 180, to: 270)
        base += arc((s.depth - frontCurve, frontCurve), frontCurve, frontCurve, from: 270, to: 360)
        base += arc((s.depth - edge, topFront - edge), edge, edge, from: 0, to: 90, steps: 4)
        base += arc((0.8, topRear - 0.8), 0.8, 0.8, from: 90, to: 180, steps: 4)
        // The side catches the light in bands: a bright top, a darker middle, the lower half
        // lighter from the table, dark where the bottom curves away.
        let mid = s.depth / 2
        add(base, across([metal(0.88), metal(0.80), metal(0.71), metal(0.77), metal(0.81), metal(0.56)],
                         (mid, (topRear + topFront) / 2), (mid, 0)))
        // Polished top edge.
        add([(0.8, topRear), (s.depth - edge, topFront), (s.depth - edge, topFront - 0.35), (0.8, topRear - 0.35)],
            .solid(RGBA(1, 1, 1, dark ? 0.55 : 0.85)))

        // Ports on the left side, centred on the side's height there.
        for port in s.ports {
            let localTop = topRear + (topFront - topRear) * port.from / s.depth
            let y = localTop * 0.5
            switch port.kind {
            case .magSafe:
                let length = 16.0, height = min(3.0, localTop * 0.5)
                add(pill(x: port.from, y: y, length: length, height: height),
                    across([metal(0.66), metal(0.86)], (port.from, y + height / 2), (port.from, y - height / 2)))
                add(pill(x: port.from + 0.5, y: y, length: length - 1, height: height - 0.9), .solid(metal(0.78)))
                for pin in 0..<5 {
                    add(pill(x: port.from + 3.2 + Double(pin) * 2.2, y: y, length: 1.4, height: 0.55), .solid(metal(0.52)))
                }
            case .usbC:
                let length = 8.4, height = min(2.5, localTop * 0.45)
                add(pill(x: port.from, y: y, length: length, height: height),
                    across([RGBA(0.05, 0.05, 0.06), RGBA(0.20, 0.20, 0.22)], (port.from, y + height / 2), (port.from, y - height / 2)))
                add(pill(x: port.from + 1.4, y: y, length: length - 2.8, height: 0.5), .solid(RGBA(0.30, 0.30, 0.32)))
            case .headphone:
                let r = min(1.8, localTop * 0.3)
                add(arc((port.from, y), r, r, from: 0, to: 360, steps: 20),
                    across([RGBA(0.05, 0.05, 0.06), RGBA(0.22, 0.22, 0.24)], (port.from, y + r), (port.from, y - r)))
            }
        }

        // Lid: a thin slab turning about the hinge; its aluminium edge, the black glass on the
        // display side, a rounded, bright top end.
        let slope = atan2(topFront - topRear, s.depth) * 180 / .pi
        let t = (slope + angle) * .pi / 180
        // `v` runs across the lid: negative towards the display, positive towards the outer cover.
        let along = (cos(t), sin(t)), outward = (-sin(t), cos(t))
        // The lid reaches `tail` past the hinge axis: closed, its back edge is flush with the
        // base; opened, that end swings down in front of the base's back corner.
        let half = s.lid / 2, tail = min(3.5, topRear * 0.5), length = s.depth - tail - 1
        let pivot = (tail, topRear + half)
        func lid(_ u: Double, _ v: Double) -> (Double, Double) {
            (pivot.0 + along.0 * u + outward.0 * v, pivot.1 + along.1 * u + outward.1 * v)
        }
        let r = min(1.2, half * 0.6)
        func corner(_ u: Double, _ v: Double, from a: Double, to b: Double) -> [(Double, Double)] {
            (0...5).map { i in
                let t = (a + (b - a) * Double(i) / 5) * .pi / 180
                return lid(u + r * cos(t), v + r * sin(t))
            }
        }
        var outline: [(Double, Double)] = []
        // Top end: a half circle from the display side over to the outer side.
        outline += (0...10).map { i -> (Double, Double) in
            let a = .pi / 2 - Double(i) / 10 * .pi
            return lid(length - half + half * cos(a), -half * sin(a))
        }
        // Hinge end: square with rounded corners.
        outline += corner(-tail + r, half - r, from: 90, to: 180)
        outline += corner(-tail + r, -half + r, from: 180, to: 270)
        // A shade darker on a light background, where the bright edge would disappear.
        let lidTone = dark ? 0.0 : 0.07
        add(outline, across([metal(0.86 - lidTone), metal(0.78 - lidTone), metal(0.68 - lidTone)],
                            lid(length / 2, half), lid(length / 2, -half)))
        // Light running along the edge, brightest at the top end; the hinge end catches it too.
        add(outline, across([RGBA(1, 1, 1, dark ? 0.30 : 0.45), RGBA(1, 1, 1, 0), RGBA(1, 1, 1, 0.05), RGBA(1, 1, 1, dark ? 0.25 : 0.30)],
                            lid(-tail, 0), lid(length, 0)))
        // The display glass seen edge on.
        let glass = min(0.7, s.lid * 0.2)
        add([lid(1, -half), lid(length - half, -half), lid(length - half, -half + glass), lid(1, -half + glass)],
            .solid(RGBA(0.06, 0.06, 0.08)))
        // Polished outer edge.
        add([lid(-tail + r, half), lid(length - half, half), lid(length - half, half - 0.3), lid(-tail + r, half - 0.3)],
            .solid(RGBA(1, 1, 1, dark ? 0.45 : 0.75)))
        return shapes
    }
}
