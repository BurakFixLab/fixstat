import Foundation
import CoreGraphics
import MacSensors

/// The lid test's notebook seen from the left side, like a product side shot: the owner's vector
/// designs of a 13" MacBook Air and a 14" MacBook Pro (980 × 653 px artboards, ≈ 3.2 px per mm)
/// drawn with CoreGraphics, the lid turned about its hinge to the measured angle. The 15" Air and
/// the 16" Pro stretch them (longer base and lid). Works in any y-down CGContext (SwiftUI
/// `Canvas`, a flipped NSView), so both interfaces can use it.
public struct NotebookSideScene {
    /// Body shapes, from published dimensions (the lid angle sensor is in the MacBook Air M2 and
    /// later and the MacBook Pro M3 and later; older bodies map to the nearest).
    public enum Body: String, CaseIterable {
        case air13, air15, pro14, pro16

        /// The body of this Mac from the product name ("MacBook Air (15-inch, M3, 2024)").
        /// `-FixStatNotebookBody air13|air15|pro14|pro16` overrides it.
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
            return name.contains("15-inch") ? .air15 : .air13
        }

        /// Extra length of base and lid over the design (13" Air 215 mm deep, 14" Pro 221.2 mm),
        /// in design pixels, and extra base thickness (none so far).
        var stretch: (dx: Double, dy: Double) {
            switch self {
            case .air13, .pro14: return (0, 0)
            case .air15: return ((237.6 - 215) * 698 / 215, 0)
            case .pro16: return ((248.1 - 221.2) * 700.7 / 221.2, 0)
            }
        }

        var isPro: Bool { self == .pro14 || self == .pro16 }
    }

    let body: Body
    private let size: CGSize

    public init(size: CGSize, body: Body) {
        self.size = size
        self.body = body
    }

    /// The design's hinge: the centre of the lid's rounded back end, in the lid's own coordinates
    /// and on the artboard (where the design shows the lid at 45°); the lid's length from there
    /// to its top end; the lowest point (feet) and the front of the base.
    private var frame: (pivotInLid: CGPoint, pivot: CGPoint, reach: Double, bottom: Double, front: Double) {
        body.isPro
            ? (CGPoint(x: -287.8, y: 486), CGPoint(x: 140.149, y: 547.16), 694.6, 588.4, 838)
            : (CGPoint(x: -294, y: 491.7), CGPoint(x: 139.795, y: 555.58), 686, 587.6, 838)
    }

    /// Fits everything the lid can reach (closed to 135°; rarely opened further, it may then
    /// leave the picture) into the picture, so the base does not move as the lid turns.
    private var fit: CGAffineTransform {
        let (dx, dy) = body.stretch
        let f = frame
        let p = f.pivot, reach = CGFloat(f.reach + dx + 6)
        let minX = p.x - reach * 0.7072, maxX = CGFloat(f.front + 4 + dx)
        let minY = p.y - reach, maxY = CGFloat(f.bottom + 2 + dy)
        let scale = min(size.width * 0.97 / (maxX - minX), size.height * 0.96 / (maxY - minY))
        return CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -(minX + maxX) / 2, y: -(minY + maxY) / 2)
    }

    /// Draws the notebook with its lid at `angle` degrees (0 = closed).
    public func draw(in ctx: CGContext, angle rawAngle: Double) {
        let angle = min(max(rawAngle, 0), 180)
        let (dx, dy) = body.stretch
        ctx.saveGState()
        ctx.concatenate(fit)
        defer { ctx.restoreGState() }
        if body.isPro {
            drawPro(ctx, angle: angle, dx: dx)
            return
        }

        // Feet.
        for x in [190.0, 724 + dx] {
            let foot = CGMutablePath()
            let y = 581 + dy
            foot.move(to: pt(x, y))
            foot.addLine(to: pt(x + 66, y))
            foot.addLine(to: pt(x + 63, y + 5.6))
            foot.addQuadCurve(to: pt(x + 61, y + 6.6), control: pt(x + 62.4, y + 6.6))
            foot.addLine(to: pt(x + 5, y + 6.6))
            foot.addQuadCurve(to: pt(x + 3, y + 5.6), control: pt(x + 3.6, y + 6.6))
            foot.closeSubpath()
            fill(ctx, foot, vertical: Self.foot, from: y, to: y + 6.6)
        }

        drawLid(ctx, angle: angle, dx: dx)
        drawBase(ctx, dx: dx, dy: dy)
        drawPorts(ctx, dy: dy)
    }

    // MARK: Lid

    /// `dx`: a longer body has a longer lid.
    private func drawLid(_ ctx: CGContext, angle: Double, dx: Double) {
        ctx.saveGState()
        turnLid(ctx, angle: angle)

        let end = 392 + dx, length = 687 + dx
        let lid = CGMutablePath()
        lid.move(to: pt(-294, 485.8))
        lid.addLine(to: pt(end - 3, 485.8))
        lid.addQuadCurve(to: pt(end, 488.8), control: pt(end, 485.8))
        lid.addLine(to: pt(end, 494.6))
        lid.addQuadCurve(to: pt(end - 3, 497.6), control: pt(end, 497.6))
        lid.addLine(to: pt(-294, 497.6))
        lid.addQuadCurve(to: pt(-300, 491.7), control: pt(-300, 497.6))
        lid.addQuadCurve(to: pt(-294, 485.8), control: pt(-300, 485.8))
        lid.closeSubpath()
        fill(ctx, lid, gradient: Self.lidAlong, from: pt(-300, 0), to: pt(end, 0))
        fill(ctx, rect(-296, 485.8, length, 2.6), gradient: Self.lidEdge, from: pt(0, 485.8), to: pt(0, 488.4))
        fill(ctx, rect(-296, 494.7, length, 0.8), hex: 0xdbe8ef, alpha: 0.6)
        fill(ctx, rect(-296, 495.45, length, 0.7), hex: 0x97a5ae, alpha: 0.65)
        fill(ctx, rounded(-297, 496.1, length + 1.6, 1.5, 0.75), hex: 0x23282d)
        fill(ctx, rounded(end - 3, 485.8, 3, 10.3, 1.2), hex: 0xeaf1f5, alpha: 0.75)
        fill(ctx, rect(end - 3.4, 486.3, 0.5, 9.6), hex: 0xa9b6bf, alpha: 0.5)
        ctx.restoreGState()
    }

    /// Lid coordinates → artboard: about the hinge, turned to the angle.
    private func turnLid(_ ctx: CGContext, angle: Double) {
        let p = frame.pivot, q = frame.pivotInLid
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: CGFloat(-angle * .pi / 180))
        ctx.translateBy(x: -q.x, y: -q.y)
    }

    // MARK: Base

    private func basePath(dx: Double, dy: Double) -> CGPath {
        let r = 838 + dx, b = 583 + dy
        let path = CGMutablePath()
        path.move(to: pt(152, 559))
        path.addLine(to: pt(r - 2.5, 559))
        path.addQuadCurve(to: pt(r, 561.5), control: pt(r, 559))
        path.addLine(to: pt(r, 572 + dy))
        path.addQuadCurve(to: pt(r - 11, b), control: pt(r, b))
        path.addLine(to: pt(158, b))
        path.addCurve(to: pt(140, 569 + dy), control1: pt(148, b), control2: pt(141, 577 + dy))
        path.addCurve(to: pt(145, 559.3), control1: pt(139.6, 564 + dy / 2), control2: pt(141.5, 560.5))
        path.addQuadCurve(to: pt(152, 559), control: pt(148, 559))
        path.closeSubpath()
        return path
    }

    private func drawBase(_ ctx: CGContext, dx: Double, dy: Double) {
        let base = basePath(dx: dx, dy: dy)
        let height = 24 + dy
        fill(ctx, base, vertical: Self.base, from: 559, to: 559 + height)

        ctx.saveGState()
        ctx.addPath(base)
        ctx.clip()
        fill(ctx, rect(150, 559, 688 + dx, height), gradient: Self.baseTone, from: pt(150, 0), to: pt(838 + dx, 0))
        // The front end's highlight, fading downwards.
        let end = rect(805 + dx, 559, 34, height)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        fill(ctx, end, gradient: Self.endShine, from: pt(805 + dx, 0), to: pt(839 + dx, 0))
        ctx.setBlendMode(.destinationIn)
        fill(ctx, end, gradient: Self.endShineV, from: pt(0, 559), to: pt(0, 559 + height))
        ctx.endTransparencyLayer()
        fill(ctx, rect(140, 559, 698 + dx, 0.9), hex: 0xeef4f7)
        // The heel under the hinge: a shadow fading forward, a dark spot.
        fill(ctx, rect(136, 555, 40, 32 + dy), gradient: Self.heelH, from: pt(136, 0), to: pt(176, 0))
        radial(ctx, Self.heelSpot, in: CGRect(x: 134, y: 552, width: 22, height: 24), centre: pt(0.42, 0.4), clipToEllipse: false)
        ctx.restoreGState()

        // The front edge's rim.
        let rim = CGMutablePath()
        let r = 836.4 + dx
        rim.move(to: pt(r, 560.2))
        rim.addLine(to: pt(r, 572 + dy))
        rim.addQuadCurve(to: pt(827 + dx, 582.2 + dy), control: pt(r, 581.6 + dy))
        ctx.saveGState()
        ctx.addPath(rim)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(Self.color(0x8796a1, 0.75))
        ctx.strokePath()
        ctx.restoreGState()
    }

    // MARK: Ports

    private func drawPorts(_ ctx: CGContext, dy: Double) {
        ctx.saveGState()
        // Ports sit at the same height of the side, a thicker base moves them down.
        ctx.translateBy(x: 0, y: CGFloat(dy / 2))
        // MagSafe.
        fill(ctx, rounded(190.5, 562, 56.5, 11, 5.5), vertical: Self.mag, from: 562, to: 573)
        fill(ctx, rounded(193, 563.6, 51.5, 8, 4), hex: 0xb4c2cc, alpha: 0.55)
        fill(ctx, rounded(201, 565.8, 33.5, 3.4, 1.4), hex: 0xa3b1bb)
        fill(ctx, rect(201, 565.8, 33.5, 0.7), hex: 0x8f9da6, alpha: 0.7)
        for i in 0..<6 {
            fill(ctx, rounded(202.2 + 5.25 * Double(i), 566.7, 4.3, 1.7, 0.6), hex: 0xdfe8ee)
        }
        // USB-C.
        for x in [263.5, 311.5] {
            fill(ctx, rounded(x, 561.6, 29, 1.6, 0.8), hex: 0xe2eaf0, alpha: 0.6)
            fill(ctx, rounded(x + 0.8, 563, 27.4, 9.4, 4.7), vertical: Self.usb, from: 563, to: 572.4)
            fill(ctx, rounded(x + 3.5, 565.9, 22, 4, 2), hex: 0x0a131b)
            fill(ctx, rounded(x + 5.1, 567, 18.8, 1.9, 0.95), hex: 0x3e474e)
        }
        ctx.restoreGState()
    }

    // MARK: MacBook Pro

    private func drawPro(_ ctx: CGContext, angle: Double, dx: Double) {
        // Feet.
        for x in [185.44, 731.25 + dx] {
            let foot = CGMutablePath()
            foot.move(to: pt(x, 582))
            foot.addLine(to: pt(x + 57.09, 582))
            foot.addLine(to: pt(x + 55.36, 587.41))
            foot.addQuadCurve(to: pt(x + 53.63, 588.36), control: pt(x + 54.93, 588.36))
            foot.addLine(to: pt(x + 4.32, 588.36))
            foot.addQuadCurve(to: pt(x + 2.59, 587.41), control: pt(x + 3.03, 588.36))
            foot.closeSubpath()
            fill(ctx, foot, vertical: Self.proFoot, from: 582, to: 588.36)
        }

        // Lid.
        ctx.saveGState()
        turnLid(ctx, angle: angle)
        let end = 406.8 + dx, length = 695.6 + dx
        let lid = CGMutablePath()
        lid.move(to: pt(-287.8, 479.8))
        lid.addLine(to: pt(end - 2.5, 479.8))
        lid.addQuadCurve(to: pt(end, 482.3), control: pt(end, 479.8))
        lid.addLine(to: pt(end, 489.7))
        lid.addQuadCurve(to: pt(end - 2.5, 492.2), control: pt(end, 492.2))
        lid.addLine(to: pt(-287.8, 492.2))
        lid.addQuadCurve(to: pt(-293.8, 486), control: pt(-293.8, 492.2))
        lid.addQuadCurve(to: pt(-287.8, 479.8), control: pt(-293.8, 479.8))
        lid.closeSubpath()
        fill(ctx, lid, gradient: Self.proLidAlong, from: pt(-293.8, 0), to: pt(end, 0))
        fill(ctx, rect(-290.8, 479.8, length, 10.8), vertical: Self.proLidCross, from: 479.8, to: 490.6)
        fill(ctx, rect(-290.8, 489.9, length, 0.7), hex: 0xc4c5c8, alpha: 0.8)
        fill(ctx, rounded(-289.8, 490.6, length - 0.5, 1.6, 0.8), hex: 0x26272a)
        fill(ctx, rounded(end - 2.6, 480.2, 2.2, 10, 1), hex: 0xf1f2f4, alpha: 0.6)
        ctx.restoreGState()

        // Base.
        let r = 837.7 + dx
        let base = CGMutablePath()
        base.move(to: pt(139, 549))
        base.addLine(to: pt(r - 2, 549))
        base.addQuadCurve(to: pt(r, 551), control: pt(r, 549))
        base.addLine(to: pt(r, 567))
        base.addCurve(to: pt(r - 17.2, 582.7), control1: pt(r, 574.5), control2: pt(r - 4.2, 580.5))
        base.addLine(to: pt(150, 582.7))
        base.addCurve(to: pt(137, 567), control1: pt(141, 581.5), control2: pt(137.4, 575))
        base.addLine(to: pt(137, 551))
        base.addQuadCurve(to: pt(139, 549), control: pt(137, 549))
        base.closeSubpath()
        fill(ctx, base, gradient: Self.proBaseAlong, from: pt(137, 0), to: pt(r, 0))
        ctx.saveGState()
        ctx.addPath(base)
        ctx.clip()
        fill(ctx, rect(130, 549, 715 + dx, 34), vertical: Self.proBaseShade, from: 549, to: 583)
        fill(ctx, rect(130, 549, 715 + dx, 0.8), hex: 0xbdbec1)
        fill(ctx, rect(130, 549.8, 715 + dx, 0.9), hex: 0xffffff, alpha: 0.45)
        // The vent slot along the bottom edge, fading out towards the front.
        let slot = rect(412.07, 576.25, 350.32 + dx, 4)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        fill(ctx, rounded(412.07, 577.03, 350.32 + dx, 1.99, 0.9), vertical: Self.proSlot, from: 577.03, to: 579.02)
        fill(ctx, rect(412.07, 579.02, 350.32 + dx, 0.8), hex: 0xffffff, alpha: 0.35)
        ctx.setBlendMode(.destinationIn)
        fill(ctx, slot, gradient: Self.proSlotFade, from: pt(412.07, 0), to: pt(762.39 + dx, 0))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        // Shadow where the lid meets the base.
        radial(ctx, Self.proHingeShade, in: CGRect(x: 135.5, y: 544.3, width: 16, height: 8.4), centre: pt(0.5, 0.5), clipToEllipse: true)

        // MagSafe 3.
        fill(ctx, rounded(213.55, 554.88, 43.25, 7.61, 3.81), vertical: Self.proMag, from: 554.88, to: 562.49)
        fill(ctx, rounded(221.34, 557.48, 30.71, 3.98, 1.38), vertical: Self.proMagSlot, from: 557.48, to: 561.46)
        for x in [225.84, 231.03, 236.65, 241.84, 247.46] {
            fill(ctx, rounded(x, 558.77, 1.38, 2.08, 0.4), hex: 0x77787c)
        }
        // Thunderbolt.
        for x in [279.03, 321.85] {
            fill(ctx, rounded(x, 554.71, 23.87, 1.3, 0.65), hex: 0xeceef0, alpha: 0.7)
            fill(ctx, rounded(x + 0.26, 555.57, 23.36, 7.79, 3.89), vertical: Self.proUsb, from: 555.57, to: 563.36)
            fill(ctx, rounded(x + 2.08, 558.6, 17.82, 1.9, 0.95), hex: 0x44464a)
        }
        // Headphone jack.
        fill(ctx, CGPath(ellipseIn: CGRect(x: 368.13 - 5.36, y: 559.38 - 5.36, width: 10.72, height: 10.72), transform: nil),
             hex: 0xc4c5c8, alpha: 0.6)
        radial(ctx, Self.proJack, in: CGRect(x: 368.13 - 4.76, y: 559.38 - 4.76, width: 9.52, height: 9.52),
               centre: pt(0.5, 0.45), clipToEllipse: true)
    }

    // MARK: Drawing helpers

    /// A radial gradient over a box (SVG objectBoundingBox units: centre and radius 0.5 relative).
    private func radial(_ ctx: CGContext, _ gradient: CGGradient, in box: CGRect, centre: CGPoint, clipToEllipse: Bool) {
        ctx.saveGState()
        ctx.addPath(clipToEllipse ? CGPath(ellipseIn: box, transform: nil) : CGPath(rect: box, transform: nil))
        ctx.clip()
        ctx.translateBy(x: box.minX, y: box.minY)
        ctx.scaleBy(x: box.width, y: box.height)
        ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: 0.5,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGPath {
        CGPath(rect: CGRect(x: x, y: y, width: w, height: h), transform: nil)
    }

    private func rounded(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ r: Double) -> CGPath {
        let radius = CGFloat(min(r, w / 2, h / 2))
        return CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func fill(_ ctx: CGContext, _ path: CGPath, hex: UInt32, alpha: Double = 1) {
        ctx.addPath(path)
        ctx.setFillColor(Self.color(hex, alpha))
        ctx.fillPath()
    }

    private func fill(_ ctx: CGContext, _ path: CGPath, gradient: CGGradient, from start: CGPoint, to end: CGPoint) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private func fill(_ ctx: CGContext, _ path: CGPath, vertical gradient: CGGradient, from top: Double, to bottom: Double) {
        fill(ctx, path, gradient: gradient, from: pt(0, top), to: pt(0, bottom))
    }

    // MARK: Colours and gradients (from the design)

    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func color(_ hex: UInt32, _ alpha: Double = 1) -> CGColor {
        let components: [CGFloat] = [CGFloat((hex >> 16) & 0xff) / 255, CGFloat((hex >> 8) & 0xff) / 255,
                                     CGFloat(hex & 0xff) / 255, CGFloat(alpha)]
        return CGColor(colorSpace: space, components: components) ?? CGColor(gray: 0.5, alpha: 1)
    }

    private static func gradient(_ stops: [(Double, UInt32, Double)]) -> CGGradient {
        let colours = stops.map { color($0.1, $0.2) } as CFArray
        let locations = stops.map { CGFloat($0.0) }
        return CGGradient(colorsSpace: space, colors: colours, locations: locations)!
    }

    private static func gradient(_ stops: [(Double, UInt32)]) -> CGGradient {
        gradient(stops.map { ($0.0, $0.1, 1.0) })
    }

    static let lidAlong = gradient([(0, 0x8e9ca5), (0.016, 0xa0aeb7), (0.035, 0xb9c8cf), (0.114, 0xd1dce2), (0.3, 0xccd8df),
                                    (0.522, 0xc6d3db), (0.8, 0xc2cfd7), (0.931, 0xbfccd4), (0.962, 0xd6e1e7),
                                    (0.98, 0xe4eff5), (1, 0xe6f0f5)])
    static let lidEdge = gradient([(0, 0xffffff, 0.7), (0.5, 0xffffff, 0.3), (1, 0xffffff, 0)])
    static let base = gradient([(0, 0xe8f0f4), (0.05, 0xd6e1e7), (0.1, 0xcfdae0), (0.33, 0xcfdae0), (0.375, 0xc8d4db),
                                (0.42, 0xb8c6cd), (0.48, 0xa5b3bc), (0.54, 0x8e9ea8), (0.6, 0x798790), (0.66, 0x727f87),
                                (0.72, 0x76838c), (0.78, 0x86939c), (0.85, 0x99a7b2), (0.91, 0xa5b7c1), (0.95, 0xa6b6be),
                                (0.98, 0x9aa7ae), (1, 0xc3ccd3)])
    static let baseTone = gradient([(0, 0x34424e, 0), (0.5, 0x34424e, 0), (0.9, 0x34424e, 0.07), (0.96, 0x34424e, 0)])
    static let endShine = gradient([(0, 0xffffff, 0), (0.5, 0xffffff, 0.45), (0.68, 0xffffff, 0.75), (0.8, 0xffffff, 0.55),
                                    (0.86, 0xffffff, 0)])
    static let endShineV = gradient([(0, 0xffffff, 1), (0.45, 0xffffff, 0.9), (0.75, 0xffffff, 0.15), (1, 0xffffff, 0)])
    static let heelH = gradient([(0, 0x3c4750, 0.9), (0.12, 0x55616b, 0.7), (0.35, 0x7f8c96, 0.3), (1, 0x7f8c96, 0)])
    static let heelSpot = gradient([(0, 0x1c2329, 0.95), (0.45, 0x2e373f, 0.6), (1, 0x2e373f, 0)])
    static let foot = gradient([(0, 0x7c8992), (0.3, 0x8a96a0), (0.55, 0x5c6670), (0.8, 0x262c32), (1, 0x4a4f55)])
    static let mag = gradient([(0, 0x5b656e), (0.14, 0x6a7680), (0.25, 0x7e8d94), (0.65, 0x84939a), (0.85, 0x9eadb4),
                               (1, 0xadbcc3)])
    static let usb = gradient([(0, 0x5e6770), (0.15, 0x252e37), (0.4, 0x141d26), (0.75, 0x2a333b), (1, 0x6a747d)])

    // MacBook Pro design.
    static let proLidAlong = gradient([(0, 0xadaeb0, 1), (0.0062, 0xd5d6d8, 1), (0.0099, 0xe8e9eb, 1),
        (0.0136, 0xe5e6e8, 1), (0.0173, 0xd5d6d8, 1), (0.021, 0xb3b4b6, 1), (0.0247, 0x999a9c, 1),
        (0.0284, 0x8f9092, 1), (0.0358, 0x969799, 1), (0.0506, 0xa8a9ab, 1), (0.0654, 0xb4b5b7, 1),
        (0.0877, 0xc1c2c4, 1), (0.1, 0xc8c9cb, 1), (0.1247, 0xd1d2d4, 1), (0.1432, 0xd5d6d8, 1),
        (0.2099, 0xd8d9db, 1), (0.2296, 0xdadbdd, 1), (0.6556, 0xdadbdd, 1), (0.8407, 0xd5d6d8, 1),
        (0.8765, 0xd1d2d4, 1), (0.8963, 0xcccdcf, 1), (0.9074, 0xc4c5c7, 1), (0.9185, 0xbcbdbf, 1),
        (0.9296, 0xb4b5b7, 1), (0.9444, 0xaaabad, 1), (0.9556, 0xa2a3a5, 1), (0.9593, 0x999a9c, 1),
        (0.9667, 0x909193, 1), (0.9704, 0x909193, 1), (0.9741, 0x9e9fa1, 1), (0.9778, 0xb6b7b9, 1),
        (0.9815, 0xd5d6d8, 1), (0.9852, 0xe4e5e7, 1), (0.9889, 0xe5e6e8, 1), (0.9926, 0xcccdcf, 1),
        (0.9963, 0xaeafb1, 1), (1, 0xbdbec0, 1)])
    static let proLidCross = gradient([(0, 0xb9babd, 1), (0.06, 0xcfd0d3, 1), (0.09, 0xffffff, 0.5),
        (0.2, 0xffffff, 0.4), (0.27, 0x7a7b80, 0.08), (0.33, 0xffffff, 0), (1, 0xffffff, 0)])
    static let proBaseAlong = gradient([(0, 0xb3b4b6, 1), (0.0025, 0xa9aaac, 1), (0.0062, 0xd6d7d9, 1),
        (0.0099, 0xecedef, 1), (0.0136, 0xe7e8ea, 1), (0.0173, 0xd1d2d4, 1), (0.021, 0xadaeb0, 1),
        (0.0247, 0x97989a, 1), (0.0284, 0x8f9092, 1), (0.0321, 0x909193, 1), (0.0358, 0x939496, 1),
        (0.0432, 0x9a9b9d, 1), (0.0506, 0x9e9fa1, 1), (0.0654, 0xa7a8aa, 1), (0.0877, 0xb8b9bb, 1),
        (0.1062, 0xc1c2c4, 1), (0.1494, 0xcccdcf, 1), (0.1988, 0xd4d5d7, 1), (0.2975, 0xd9dadc, 1),
        (0.5321, 0xd8d9db, 1), (0.8037, 0xd1d2d4, 1), (0.8407, 0xcccdcf, 1), (0.8778, 0xc9cacc, 1),
        (0.8889, 0xc7c8ca, 1), (0.9, 0xbdbec0, 1), (0.9111, 0xb5b6b8, 1), (0.9222, 0xadaeb0, 1),
        (0.9333, 0xa7a8aa, 1), (0.9444, 0xa2a3a5, 1), (0.9556, 0x9a9b9d, 1), (0.963, 0x949597, 1),
        (0.9667, 0x8d8e90, 1), (0.9704, 0x909193, 1), (0.9741, 0x9d9ea0, 1), (0.9778, 0xb2b3b5, 1),
        (0.9815, 0xd5d6d8, 1), (0.9852, 0xe7e8ea, 1), (0.9889, 0xe7e8ea, 1), (0.9926, 0xcdced0, 1),
        (0.9963, 0xa9aaac, 1), (1, 0xbdbec0, 1)])
    static let proBaseShade = gradient([(0, 0x1c1e22, 0.065), (0.0504, 0x1c1e22, 0), (0.4282, 0x1c1e22, 0),
        (0.4534, 0x1c1e22, 0.06), (0.4786, 0x1c1e22, 0.106), (0.5038, 0x1c1e22, 0.134), (0.529, 0x1c1e22, 0.143),
        (0.5542, 0x1c1e22, 0.161), (0.5793, 0x1c1e22, 0.189), (0.6045, 0x1c1e22, 0.226), (0.6297, 0x1c1e22, 0.253),
        (0.6549, 0x1c1e22, 0.29), (0.6927, 0x1c1e22, 0.304), (0.7305, 0x1c1e22, 0.295), (0.7557, 0x1c1e22, 0.286),
        (0.7809, 0x1c1e22, 0.267), (0.806, 0x1c1e22, 0.226), (0.8312, 0x1c1e22, 0.184), (0.8564, 0x1c1e22, 0.11),
        (0.8816, 0x1c1e22, 0.065), (0.9068, 0x1c1e22, 0.014), (0.932, 0x1c1e22, 0), (0.9572, 0x1c1e22, 0.12),
        (0.9899, 0x1c1e22, 0.34)])
    static let proSlot = gradient([(0, 0x3b3c3f, 1), (0.45, 0x333436, 1), (1, 0x7a7b7e, 1)])
    static let proSlotFade = gradient([(0, 0xffffff, 1), (0.88, 0xffffff, 1), (1, 0xffffff, 0)])
    static let proFoot = gradient([(0, 0x9b9c9f, 1), (0.35, 0x6f7074, 1), (0.7, 0x2a2b2e, 1), (1, 0x1b1c1e, 1)])
    static let proMag = gradient([(0, 0x7c7d81, 1), (0.15, 0x86878b, 1), (0.35, 0x9fa0a4, 1), (0.7, 0xb1b2b6, 1),
        (1, 0xbcbdc1, 1)])
    static let proMagSlot = gradient([(0, 0x58595c, 1), (0.25, 0x2a2b2e, 1), (0.75, 0x262729, 1), (1, 0x6f7073, 1)])
    static let proUsb = gradient([(0, 0x3a3b3e, 1), (0.12, 0x141517, 1), (0.85, 0x141517, 1), (1, 0x646568, 1)])
    static let proJack = gradient([(0, 0x1a1b1d, 1), (0.75, 0x161719, 1), (0.9, 0x3a3b3e, 1), (1, 0x8a8b8f, 1)])
    static let proHingeShade = gradient([(0, 0x1b1c1f, 0.85), (0.5, 0x2b2c30, 0.45), (1, 0x2b2c30, 0)])
}
