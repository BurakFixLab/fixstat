import Foundation
import CoreGraphics
import MacSensors

/// The lid test's notebook seen from the side, in the shape of this Mac's body (flat MacBook Air,
/// wedge MacBook Air, MacBook Pro with feet), true to scale in millimetres: the lid turns about
/// the hinge, a dial around the hinge shows the angle and the display lights the space between
/// lid and keyboard. Returned as filled polygons, back to front, like `NotebookScene`, so both
/// interfaces draw the same picture. Front of the notebook on the right, hinge on the left.
public struct NotebookSideScene {
    public typealias RGBA = NotebookScene.RGBA
    public typealias Shape = NotebookScene.Shape

    /// Body shapes (side profile), from published dimensions.
    public enum Body: String, CaseIterable {
        /// MacBook Air M2 and later, MacBook 12": flat, 11.3 mm.
        case air13, air15
        /// MacBook Air before M2: a wedge, 16 mm at the hinge, 4 mm at the front.
        case wedge
        /// MacBook Pro 14" / 16" (2021 and later) with feet; also the older, thinner Pros.
        case pro14, pro16

        /// The body of this Mac: from the product name ("MacBook Air (15-inch, M3, 2024)") and
        /// the model identifier (`MacBookAir…` = before M2, a wedge).
        /// `-FixStatNotebookBody air13|air15|wedge|pro14|pro16` overrides it.
        public static func current(system: SystemInfo = .current()) -> Body {
            if let raw = UserDefaults.standard.string(forKey: "FixStatNotebookBody"), let body = Body(rawValue: raw) {
                return body
            }
            return of(marketingName: system.marketingName, model: system.model)
        }

        static func of(marketingName: String?, model: String) -> Body {
            let name = marketingName?.lowercased() ?? ""
            if name.contains("macbook pro") || model.hasPrefix("MacBookPro") {
                return name.contains("16-inch") || name.contains("15-inch") ? .pro16 : .pro14
            }
            if model.hasPrefix("MacBookAir") { return .wedge }
            return name.contains("15-inch") ? .air15 : .air13
        }

        /// Depth, base thickness at the hinge and at the front, lid thickness, front corner
        /// radius, feet height (millimetres; thicknesses drawn `exaggeration` times thicker, or
        /// at this size the body would be two lines).
        var size: (depth: Double, rear: Double, front: Double, lid: Double, radius: Double, feet: Double) {
            let s = published
            let k = NotebookSideScene.exaggeration
            return (s.depth, s.rear * k, s.front * k, s.lid * k, s.radius * k, s.feet * k)
        }

        private var published: (depth: Double, rear: Double, front: Double, lid: Double, radius: Double, feet: Double) {
            switch self {
            case .air13: return (215, 6.6, 6.6, 4.7, 2.5, 0.5)
            case .air15: return (238, 6.6, 6.6, 4.7, 2.5, 0.5)
            case .wedge: return (212, 11.5, 2.4, 4.4, 1.2, 0.5)
            case .pro14: return (221, 10.4, 10.4, 5.1, 4.0, 1.4)
            case .pro16: return (248, 11.4, 11.4, 5.4, 4.5, 1.4)
            }
        }
    }

    static let exaggeration = 1.8
    let body: Body
    let dark: Bool
    private var scale = 1.0, origin = CGPoint.zero

    /// `size`: the picture's size in points; the model is fitted once for every angle (closed to
    /// laid flat), so it does not move as the lid turns.
    public init(size: CGSize, body: Body, dark: Bool) {
        self.body = body
        self.dark = dark
        let s = body.size
        // Fitted for the lid up to 135° (rarely opened further; it may then leave the picture).
        let lid = lidLength
        let minX = -lid * 0.71 - s.lid, maxX = s.depth + 2, minY = -s.feet - 6, maxY = s.rear + lid + s.lid
        scale = min(Double(size.width) * 0.96 / (maxX - minX), Double(size.height) * 0.94 / (maxY - minY))
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2
        origin = CGPoint(x: size.width / 2 - CGFloat(midX * scale), y: size.height / 2 + CGFloat(midY * scale))
    }

    private var lidLength: Double { body.size.depth - 4 }

    /// Millimetres (y up) to points (y down).
    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(x * scale), y: origin.y - CGFloat(y * scale))
    }

    private func arc(_ cx: Double, _ cy: Double, _ r: Double, from a: Double, to b: Double, steps: Int = 10) -> [(Double, Double)] {
        (0...steps).map { i in
            let t = (a + (b - a) * Double(i) / Double(steps)) * .pi / 180
            return (cx + r * cos(t), cy + r * sin(t))
        }
    }

    private var aluminium: (light: RGBA, dark: RGBA) {
        dark ? (RGBA(0.66, 0.67, 0.70), RGBA(0.36, 0.37, 0.40)) : (RGBA(0.93, 0.93, 0.95), RGBA(0.70, 0.71, 0.74))
    }

    private func vertical(_ points: [CGPoint], _ top: RGBA, _ bottom: RGBA) -> NotebookScene.Fill {
        let ys = points.map(\.y), x = points.first?.x ?? 0
        return .gradient([top, bottom], CGPoint(x: x, y: ys.min() ?? 0), CGPoint(x: x, y: ys.max() ?? 0))
    }

    /// The polygons for this lid angle (degrees, 0 = closed), back to front.
    public func shapes(angle rawAngle: Double, hasReading: Bool = true, accent: RGBA = RGBA(0.25, 0.48, 1.0)) -> [Shape] {
        let angle = min(max(rawAngle, 0), 180)
        let s = body.size
        var shapes: [Shape] = []
        func add(_ points: [(Double, Double)], _ fill: (([CGPoint]) -> NotebookScene.Fill)) {
            let projected = points.map { point($0.0, $0.1) }
            shapes.append(Shape(points: projected, fill: fill(projected)))
        }

        // The base's top surface runs from the hinge down to the front (sloped on a wedge).
        let slope = atan2(s.front - s.rear, s.depth) * 180 / .pi
        let pivot = (x: s.lid / 2 + 1.0, y: s.rear + s.lid / 2)
        let lidDirection = slope + angle
        let t = lidDirection * .pi / 180
        let along = (x: cos(t), y: sin(t)), inner = (x: sin(t), y: -cos(t))
        func lidPoint(_ u: Double, _ v: Double) -> (Double, Double) {
            (pivot.x + along.x * u + inner.x * v, pivot.y + along.y * u + inner.y * v)
        }

        // Shadow on the table.
        add([(-2, -s.feet - 1.5), (s.depth + 2, -s.feet - 1.5), (s.depth - 6, -s.feet - 4.5), (4, -s.feet - 4.5)]) { _ in
            .shadow(RGBA(0, 0, 0, self.dark ? 0.75 : 0.35), CGFloat(3.5 * self.scale))
        }

        // Dial around the hinge: the half circle (0…180°) with ticks every 30°.
        let radius = s.depth * 0.42
        let dialColour = dark ? RGBA(1, 1, 1, 0.16) : RGBA(0, 0, 0, 0.14)
        let ring = arc(pivot.x, pivot.y, radius, from: slope, to: slope + 180, steps: 48)
        let ringInner = arc(pivot.x, pivot.y, radius - 0.9, from: slope + 180, to: slope, steps: 48)
        add(ring + ringInner) { _ in .solid(dialColour) }
        for tick in stride(from: 0.0, through: 180, by: 30) {
            let a = (slope + tick) * .pi / 180, n = (x: -sin(a), y: cos(a)), c = (x: cos(a), y: sin(a))
            let r0 = radius + 2, r1 = radius + (tick.truncatingRemainder(dividingBy: 90) == 0 ? 8 : 5), half = 0.45
            add([(pivot.x + c.x * r0 + n.x * half, pivot.y + c.y * r0 + n.y * half),
                 (pivot.x + c.x * r1 + n.x * half, pivot.y + c.y * r1 + n.y * half),
                 (pivot.x + c.x * r1 - n.x * half, pivot.y + c.y * r1 - n.y * half),
                 (pivot.x + c.x * r0 - n.x * half, pivot.y + c.y * r0 - n.y * half)]) { _ in .solid(dialColour) }
        }

        // The swept angle: a soft sector and a bright arc up to the lid.
        if hasReading, angle > 0.5 {
            let steps = max(Int(angle / 4), 2)
            let sector = [(pivot.x, pivot.y)] + arc(pivot.x, pivot.y, radius, from: slope, to: lidDirection, steps: steps)
            add(sector) { points in
                .gradient([accent.with(alpha: 0.02), accent.with(alpha: self.dark ? 0.22 : 0.16)],
                          self.point(pivot.x, pivot.y), points[points.count / 2])
            }
            let outer = arc(pivot.x, pivot.y, radius + 1.2, from: slope, to: lidDirection, steps: steps)
            let inside = arc(pivot.x, pivot.y, radius - 1.6, from: lidDirection, to: slope, steps: steps)
            add(outer + inside) { points in
                .gradient([accent.with(alpha: 0.35), accent], points.first ?? .zero, points[steps])
            }
        }

        // The display's light falling on the keyboard, between the lid and the base.
        let awake = hasReading ? min(max((angle - 18) / 14, 0), 1) : 0.25
        if awake > 0.01 {
            let reach = min(lidLength * 0.95, s.depth - 8)
            let top = lidPoint(lidLength * 0.92, -s.lid / 2), bottom = lidPoint(6, -s.lid / 2)
            let far = (pivot.x + reach, s.rear + (s.front - s.rear) * reach / s.depth)
            let glowColour = RGBA(0.50, 0.42, 1.0)
            add([bottom, top, far, (pivot.x + 4, s.rear)]) { _ in
                .shadow(glowColour.with(alpha: (self.dark ? 0.20 : 0.10) * awake), CGFloat(14 * self.scale))
            }
        }

        // Base: rounded at the hinge and at the front, feet below.
        if s.feet > 0.6 {
            for x in [16.0, s.depth - 30] {
                add([(x, -s.feet), (x + 14, -s.feet), (x + 14, 0.5), (x, 0.5)]) { _ in .solid(RGBA(0.08, 0.08, 0.09)) }
            }
        }
        let rearRadius = min(s.rear / 2, 4.0), frontRadius = min(s.radius, s.front / 2)
        var base: [(Double, Double)] = []
        base += arc(rearRadius, rearRadius, rearRadius, from: 180, to: 270, steps: 6)
        base += arc(s.depth - frontRadius, frontRadius, frontRadius, from: 270, to: 360, steps: 6)
        base += arc(s.depth - frontRadius, s.front - frontRadius, frontRadius, from: 0, to: 90, steps: 6)
        base += arc(rearRadius, s.rear - rearRadius, rearRadius, from: 90, to: 180, steps: 6)
        add(base) { points in self.vertical(points, self.aluminium.light, self.aluminium.dark) }
        // A polished chamfer along the top edge.
        add([(rearRadius, s.rear), (s.depth - frontRadius, s.front), (s.depth - frontRadius, s.front - 0.5), (rearRadius, s.rear - 0.5)]) { _ in
            .solid(RGBA(1, 1, 1, self.dark ? 0.35 : 0.8))
        }

        // Lid: a capsule turning about the hinge, aluminium outside, black glass inside.
        let halfLid = s.lid / 2
        var lid: [(Double, Double)] = []
        // The far end (top edge of the display): half circle from the inner to the outer side.
        for i in 0...10 {
            let a = -Double.pi / 2 + Double(i) / 10 * .pi
            lid.append(lidPoint(lidLength - halfLid + halfLid * cos(a), halfLid * sin(a) * -1))
        }
        // The hinge end: half circle back round to the inner side.
        for i in 0...10 {
            let a = Double.pi / 2 + Double(i) / 10 * .pi
            lid.append(lidPoint(halfLid * cos(a), halfLid * sin(a) * -1))
        }
        add(lid) { points in
            let a = self.point(pivot.x, pivot.y)
            let far = self.point(lidPoint(self.lidLength, 0).0, lidPoint(self.lidLength, 0).1)
            return .gradient([self.aluminium.dark, self.aluminium.light, self.aluminium.dark], a, far)
        }
        let glass = 1.0
        add([lidPoint(3, -halfLid), lidPoint(lidLength - halfLid, -halfLid),
             lidPoint(lidLength - halfLid, -halfLid + glass), lidPoint(3, -halfLid + glass)]) { _ in
            .solid(RGBA(0.03, 0.03, 0.04))
        }
        // The display's edge glows while it is on.
        if awake > 0.01 {
            add([lidPoint(8, -halfLid - 0.05), lidPoint(lidLength - halfLid - 4, -halfLid - 0.05),
                 lidPoint(lidLength - halfLid - 4, -halfLid + 0.35), lidPoint(8, -halfLid + 0.35)]) { points in
                .gradient([RGBA(0.30, 0.45, 1.0, awake), RGBA(0.60, 0.35, 0.95, awake), RGBA(1.0, 0.55, 0.45, awake)],
                          points[0], points[1])
            }
        }
        // Hinge barrel.
        let barrel = arc(pivot.x, pivot.y, halfLid * 0.75, from: 0, to: 360, steps: 20)
        add(barrel) { points in self.vertical(points, RGBA(0.22, 0.22, 0.24), RGBA(0.08, 0.08, 0.09)) }
        return shapes
    }
}

extension NotebookScene.RGBA {
    func with(alpha: Double) -> NotebookScene.RGBA { NotebookScene.RGBA(r, g, b, alpha) }
}
