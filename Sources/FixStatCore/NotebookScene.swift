import Foundation
import CoreGraphics

/// The lid test's notebook, drawn in 3D: a base (aluminium box with keyboard and trackpad) and
/// a lid with thickness, screen, bezel and notch, turning about the hinge. The scene is projected
/// with a perspective camera in front of and above the notebook and returned as filled
/// polygons, back to front, so the SwiftUI canvas and the AppKit view draw the same picture.
/// Faces are shaded by a light from the upper left, rounded corners are sampled.
public struct NotebookScene {
    public struct RGBA: Equatable {
        public var r, g, b, a: Double
        public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
        func scaled(_ k: Double) -> RGBA { RGBA(min(r * k, 1), min(g * k, 1), min(b * k, 1), a) }
        func mixed(with o: RGBA, _ t: Double) -> RGBA {
            RGBA(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t, a + (o.a - a) * t)
        }
    }

    public enum Fill {
        case solid(RGBA)
        /// Linear gradient between two points of the picture.
        case gradient([RGBA], CGPoint, CGPoint)
        /// A soft shadow: fill with this colour and blur by the radius.
        case shadow(RGBA, CGFloat)
    }

    public struct Shape {
        public var points: [CGPoint]
        public var fill: Fill
    }

    struct Vec: Equatable {
        var x, y, z: Double
        init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
        static func + (a: Vec, b: Vec) -> Vec { Vec(a.x + b.x, a.y + b.y, a.z + b.z) }
        static func - (a: Vec, b: Vec) -> Vec { Vec(a.x - b.x, a.y - b.y, a.z - b.z) }
        static func * (a: Vec, k: Double) -> Vec { Vec(a.x * k, a.y * k, a.z * k) }
        func dot(_ o: Vec) -> Double { x * o.x + y * o.y + z * o.z }
        func cross(_ o: Vec) -> Vec { Vec(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
        var normalized: Vec { let l = sqrt(dot(self)); return l > 0 ? self * (1 / l) : self }
    }

    // Model size (arbitrary units): base width, depth, thickness; lid height and thickness.
    static let width = 300.0, depth = 210.0, baseThickness = 10.0, lidHeight = 200.0, lidThickness = 5.0

    let dark: Bool
    let camera = Vec(-120, 250, 560)
    let target = Vec(0, 70, 70)
    let light = Vec(-0.45, 0.85, 0.35).normalized
    private let forward: Vec, right: Vec, up: Vec
    private var focal = 1.0, center = CGPoint.zero

    /// `size`: the picture's size in points; the model is fitted into it once for every angle, so
    /// it does not move as the lid turns.
    public init(size: CGSize, dark: Bool) {
        self.dark = dark
        forward = (target - camera).normalized
        right = forward.cross(Vec(0, 1, 0)).normalized
        up = right.cross(forward).normalized
        fit(into: size)
    }

    // MARK: Camera

    private func cameraSpace(_ p: Vec) -> Vec {
        let rel = p - camera
        return Vec(rel.dot(right), rel.dot(up), rel.dot(forward))
    }

    private func project(_ p: Vec) -> CGPoint {
        let c = cameraSpace(p)
        return CGPoint(x: center.x + CGFloat(focal * c.x / c.z), y: center.y - CGFloat(focal * c.y / c.z))
    }

    private mutating func fit(into size: CGSize) {
        // Everything the lid can reach between closed and laid back, plus the base.
        var points = box(Self.baseCorners)
        for angle in [0.0, 90, 140] { points += lidCorners(angle) }
        focal = 1
        center = .zero
        let projected = points.map(project)
        let xs = projected.map(\.x), ys = projected.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
        let scale = min(size.width * 0.94 / (maxX - minX), size.height * 0.90 / (maxY - minY))
        focal = Double(scale)
        center = CGPoint(x: size.width / 2 - (minX + maxX) / 2 * scale, y: size.height / 2 - (minY + maxY) / 2 * scale)
    }

    // MARK: Geometry

    static var baseCorners: (Vec, Vec) {
        (Vec(-width / 2, -baseThickness, 0), Vec(width / 2, 0, depth))
    }

    private func box(_ corners: (Vec, Vec)) -> [Vec] {
        let (a, b) = corners
        return [Vec(a.x, a.y, a.z), Vec(b.x, a.y, a.z), Vec(a.x, b.y, a.z), Vec(b.x, b.y, a.z),
                Vec(a.x, a.y, b.z), Vec(b.x, a.y, b.z), Vec(a.x, b.y, b.z), Vec(b.x, b.y, b.z)]
    }

    /// Unit vector from the hinge along the lid (0° lies on the base towards the front, 90°
    /// stands upright), and the screen's normal.
    private func lidAxes(_ angle: Double) -> (along: Vec, normal: Vec) {
        let t = angle * .pi / 180
        return (Vec(0, sin(t), cos(t)), Vec(0, -cos(t), sin(t)))
    }

    private func lidCorners(_ angle: Double) -> [Vec] {
        let (along, normal) = lidAxes(angle)
        let hinge = Vec(0, Self.lidThickness / 2, 0)
        var corners: [Vec] = []
        for x in [-Self.width / 2, Self.width / 2] {
            for u in [0, Self.lidHeight] {
                let p = hinge + Vec(x, 0, 0) + along * u
                corners.append(p + normal * (Self.lidThickness / 2))
                corners.append(p - normal * (Self.lidThickness / 2))
            }
        }
        return corners
    }

    /// A rounded rectangle on a plane: origin, unit axes, size, corner radius; sampled corners.
    private func roundedRect(origin: Vec, u: Vec, v: Vec, width: Double, height: Double, radius: Double) -> [Vec] {
        let r = min(radius, width / 2, height / 2)
        var points: [Vec] = []
        let centers = [(width - r, height - r, 0.0), (r, height - r, 90.0), (r, r, 180.0), (width - r, r, 270.0)]
        for (cx, cy, start) in centers {
            for step in 0...5 {
                let a = (start + Double(step) * 18) * .pi / 180
                let x = cx + r * cos(a), y = cy + r * sin(a)
                points.append(origin + u * x + v * y)
            }
        }
        return points
    }

    /// The side walls between two parallel outlines of a slab, the ones facing the camera.
    private func walls(_ a: [Vec], _ b: [Vec]) -> [(points: [Vec], normal: Vec)] {
        let count = a.count
        let centroid = (a + b).reduce(Vec(0, 0, 0), +) * (1 / Double(2 * count))
        var result: [(points: [Vec], normal: Vec)] = []
        for i in 0..<count {
            let j = (i + 1) % count
            let middle = (a[i] + a[j] + b[i] + b[j]) * 0.25
            var normal = (a[j] - a[i]).cross(b[i] - a[i]).normalized
            if normal.dot(middle - centroid) < 0 { normal = normal * -1 }
            guard (camera - middle).dot(normal) > 0 else { continue }
            result.append(([a[i], a[j], b[j], b[i]], normal))
        }
        return result
    }

    private func faces(toward point: Vec, center: Vec, normal: Vec) -> Bool {
        (camera - center).dot(normal) > 0
    }

    // MARK: Colours

    private var aluminium: RGBA { dark ? RGBA(0.47, 0.48, 0.51) : RGBA(0.84, 0.85, 0.87) }

    private func shade(_ base: RGBA, normal: Vec) -> RGBA {
        base.scaled(0.62 + 0.48 * max(0, normal.dot(light)))
    }

    private func gradient(_ colour: RGBA, over polygon: [CGPoint], lighter: Double = 1.10, darker: Double = 0.90) -> Fill {
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let start = CGPoint(x: xs.min() ?? 0, y: ys.min() ?? 0), end = CGPoint(x: xs.max() ?? 0, y: ys.max() ?? 0)
        return .gradient([colour.scaled(lighter), colour.scaled(darker)], start, end)
    }

    // MARK: Picture

    /// The polygons for this lid angle (degrees, 0 = closed), back to front.
    public func shapes(angle rawAngle: Double, hasReading: Bool = true) -> [Shape] {
        let angle = min(max(rawAngle, 0), 180)
        var shapes: [Shape] = []
        func add(_ points: [Vec], _ fill: Fill) { shapes.append(Shape(points: points.map(project), fill: fill)) }
        // Walls are flat-shaded: per-segment gradients would show the facets of rounded corners.
        func addWall(_ wall: (points: [Vec], normal: Vec), _ colour: RGBA) {
            add(wall.points, .solid(shade(colour, normal: wall.normal)))
        }
        func addShaded(_ points: [Vec], _ colour: RGBA, normal: Vec) {
            let projected = points.map(project)
            shapes.append(Shape(points: projected, fill: gradient(shade(colour, normal: normal), over: projected)))
        }

        let w = Self.width, d = Self.depth, t = Self.baseThickness
        // Soft shadow on the table.
        add(roundedRect(origin: Vec(-w / 2 - 6, -t - 0.5, -4), u: Vec(1, 0, 0), v: Vec(0, 0, 1),
                        width: w + 12, height: d + 14, radius: 30),
            .shadow(RGBA(0, 0, 0, dark ? 0.60 : 0.30), 14))

        // Base: a rounded slab; its walls, then the top.
        let top = roundedRect(origin: Vec(-w / 2, 0, d), u: Vec(1, 0, 0), v: Vec(0, 0, -1), width: w, height: d, radius: 12)
        let bottom = top.map { $0 + Vec(0, -t, 0) }
        for wall in walls(top, bottom) { addWall(wall, aluminium.scaled(0.93)) }
        addShaded(top, aluminium, normal: Vec(0, 1, 0))
        let inset = roundedRect(origin: Vec(-w / 2 + 1.2, 0.05, d - 1.2), u: Vec(1, 0, 0), v: Vec(0, 0, -1),
                                width: w - 2.4, height: d - 2.4, radius: 11)
        shapes.append(Shape(points: top.map(project) + inset.reversed().map(project),
                            fill: .solid(RGBA(1, 1, 1, dark ? 0.10 : 0.35))))

        // Keyboard well, keys, trackpad.
        let keyColour = dark ? RGBA(0.10, 0.10, 0.11) : RGBA(0.16, 0.16, 0.17)
        let well = roundedRect(origin: Vec(-w * 0.44, 0.1, d * 0.50), u: Vec(1, 0, 0), v: Vec(0, 0, -1),
                               width: w * 0.88, height: d * 0.44, radius: 5)
        add(well, .solid(aluminium.scaled(0.80)))
        let rows = 6, columns = 14
        let gap = 2.4, wellX = -w * 0.43, wellZ = d * 0.08, wellWidth = w * 0.86, wellDepth = d * 0.41
        let keyWidth = (wellWidth - gap * Double(columns + 1)) / Double(columns)
        var z = wellZ + gap
        for row in 0..<rows {
            let keyDepth = row == 0 ? 6.0 : (wellDepth - gap * Double(rows + 1) - 6) / Double(rows - 1)
            var x = wellX + gap
            var column = 0
            while column < columns {
                // The space bar takes six keys in the bottom row.
                let span = row == rows - 1 && column == 4 ? 6 : 1
                let kw = keyWidth * Double(span) + gap * Double(span - 1)
                add(roundedRect(origin: Vec(x, 0.4, z + keyDepth), u: Vec(1, 0, 0), v: Vec(0, 0, -1),
                                width: kw, height: keyDepth, radius: 1.6), .solid(keyColour))
                x += kw + gap
                column += span
            }
            z += keyDepth + gap
        }
        let pad = roundedRect(origin: Vec(-w * 0.22, 0.2, d * 0.95), u: Vec(1, 0, 0), v: Vec(0, 0, -1),
                              width: w * 0.44, height: d * 0.38, radius: 7)
        let padPoints = pad.map(project)
        shapes.append(Shape(points: padPoints, fill: gradient(shade(aluminium.scaled(1.04), normal: Vec(0, 1, 0)),
                                                              over: padPoints, lighter: 1.06, darker: 0.96)))

        // Lid. The display's light on the keyboard, stronger as the lid comes down over it.
        let (along, normal) = lidAxes(angle)
        let awake = hasReading ? min(max((angle - 18) / 14, 0), 1) : 0.25
        let facing = min(max(cos((angle - 60) * .pi / 180), 0), 1)
        if awake * facing > 0.01 {
            let glow = roundedRect(origin: Vec(-w * 0.36, 0.5, d * 0.42), u: Vec(1, 0, 0), v: Vec(0, 0, -1),
                                   width: w * 0.72, height: d * 0.36, radius: 20)
            add(glow, .shadow(RGBA(0.45, 0.38, 0.95, (dark ? 0.30 : 0.14) * awake * facing), 16))
        }
        let hinge = Vec(0, Self.lidThickness / 2, 0)
        let half = Self.lidThickness / 2, h = Self.lidHeight
        let frontOrigin = hinge + Vec(-w / 2, 0, 0) + normal * half
        let backOrigin = hinge + Vec(-w / 2, 0, 0) - normal * half
        let back = roundedRect(origin: backOrigin, u: Vec(1, 0, 0), v: along, width: w, height: h, radius: 12)
        let front = roundedRect(origin: frontOrigin, u: Vec(1, 0, 0), v: along, width: w, height: h, radius: 12)
        // A convex solid: its visible faces never overlap, so culling the hidden ones is enough.
        for wall in walls(front, back) { addWall(wall, aluminium.scaled(0.95)) }
        if faces(toward: camera, center: hinge - normal * half + along * (h / 2), normal: normal * -1) {
            addShaded(back, aluminium, normal: normal * -1)
        }

        // Its front: black glass, the display (dimming as the lid closes), the notch, a reflection.
        if faces(toward: camera, center: hinge + normal * half + along * (h / 2), normal: normal) {
            add(front, .solid(RGBA(0.04, 0.04, 0.05)))
            let lift = normal * 0.3
            let screen = roundedRect(origin: frontOrigin + lift + Vec(9, 0, 0) + along * 9, u: Vec(1, 0, 0), v: along,
                                     width: w - 18, height: h - 22, radius: 6)
            let screenPoints = screen.map(project)
            // Asleep below ~25°: the display goes dark.
            let colours = [RGBA(0.18, 0.36, 0.92), RGBA(0.52, 0.28, 0.84), RGBA(0.98, 0.55, 0.42)]
                .map { RGBA(0.03, 0.03, 0.05).mixed(with: $0, awake) }
            let xs = screenPoints.map(\.x), ys = screenPoints.map(\.y)
            shapes.append(Shape(points: screenPoints,
                                fill: .gradient(colours, CGPoint(x: xs.min() ?? 0, y: ys.min() ?? 0),
                                                CGPoint(x: xs.max() ?? 0, y: ys.max() ?? 0))))
            let notch = roundedRect(origin: frontOrigin + lift * 2 + Vec(w / 2 - 18, 0, 0) + along * (h - 13),
                                    u: Vec(1, 0, 0), v: along, width: 36, height: 13, radius: 4)
            add(notch, .solid(RGBA(0.04, 0.04, 0.05)))
            let shine = roundedRect(origin: frontOrigin + lift * 3, u: Vec(1, 0, 0), v: along,
                                    width: w, height: h, radius: 12).map(project)
            let sx = shine.map(\.x), sy = shine.map(\.y)
            shapes.append(Shape(points: shine, fill: .gradient([RGBA(1, 1, 1, 0.13), RGBA(1, 1, 1, 0), RGBA(1, 1, 1, 0)],
                                                                CGPoint(x: sx.min() ?? 0, y: sy.min() ?? 0),
                                                                CGPoint(x: sx.max() ?? 0, y: sy.max() ?? 0))))
        }
        return shapes
    }
}
