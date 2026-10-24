import SwiftUI

/// Procedural swirl-and-flower artwork used by the pink and Miku themes.
/// Grows in from the left edge and fades out before the right edge.
struct SwirlArt: View {
    let ink: Color
    let soft: Color

    var body: some View {
        Canvas { ctx, size in
            let W = size.width, H = size.height
            let u = min(W, H * 0.55)            // size unit
            func P(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * W, y: y * H) }
            ctx.drawLayer { l in
                // soft rings
                for (cx, cy, r) in [(0.18, 0.30, 0.34), (0.18, 0.30, 0.26), (0.22, 0.72, 0.30), (0.22, 0.72, 0.20)] {
                    let c = P(cx, cy), R = r * u
                    l.stroke(Path(ellipseIn: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)),
                             with: .color(.white.opacity(0.16)), lineWidth: 0.05 * u)
                }
                var g = LCG(7)
                for _ in 0..<14 {
                    let x = g.next() * 0.55, y = g.next(), r = (0.01 + g.next() * 0.03) * u
                    let c = P(x, y)
                    l.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(0.22)))
                }
                g = LCG(21)
                for (cx, cy, spread) in [(0.04, 0.66, 0.26), (0.10, 0.28, 0.18)] {
                    for _ in 0..<46 {
                        let a = g.next() * 2 * Double.pi, d = g.next().squareRoot() * spread
                        let x = cx + cos(a) * d * 0.8, y = cy + sin(a) * d
                        let r = (0.006 + g.next() * 0.016) * u
                        let c = P(x, y), al = 0.45 * (1 - d / spread) + 0.1
                        l.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                 with: .color(soft.opacity(al)), lineWidth: max(1, 0.0035 * u))
                    }
                }
                // tendrils: control points, spiral radius, turns, direction, w0, w1, strong
                let tendrils: [([(Double, Double)], Double, Double, Double, Double, Double, Bool)] = [
                    ([(-0.06,1.04),(0.10,0.90),(0.24,0.74),(0.31,0.55),(0.22,0.36),(0.08,0.24)],0.09,1.9,1,0.034,0.004,true),
                    ([(-0.06,0.62),(0.08,0.55),(0.26,0.52),(0.42,0.44),(0.56,0.34)],0.11,2.1,-1,0.030,0.004,true),
                    ([(0.02,1.05),(0.20,0.99),(0.40,0.95),(0.55,0.86),(0.66,0.78)],0.08,1.8,-1,0.028,0.004,false),
                    ([(-0.06,0.20),(0.06,0.13),(0.20,0.07),(0.34,0.06)],0.07,1.9,1,0.022,0.004,false),
                    ([(0.22,0.74),(0.34,0.80),(0.46,0.76),(0.53,0.66)],0.055,1.7,1,0.018,0.003,false),
                    ([(0.30,0.52),(0.20,0.40),(0.28,0.27),(0.44,0.22)],0.06,1.7,-1,0.018,0.003,false),
                    ([(-0.06,0.44),(0.04,0.36),(0.15,0.38),(0.20,0.46)],0.04,1.6,1,0.016,0.003,false),
                ]
                for (ctrl, sr, turns, dir, w0, w1, strong) in tendrils {
                    let pts = SwirlArt.catmull(ctrl.map { CGPoint(x: $0.0 * W, y: $0.1 * H) })
                    let e = pts[pts.count - 1], b = pts[pts.count - 4]
                    let sp = SwirlArt.spiral(end: e, tangent: CGPoint(x: e.x - b.x, y: e.y - b.y), r0: sr * u, turns: turns, dir: dir)
                    let full = pts + sp
                    l.fill(SwirlArt.ribbon(full, w0 * u, w1 * u), with: .color(ink.opacity(strong ? 0.85 : 0.62)))
                    var lg = LCG(UInt32(abs(ctrl[0].0 * 1000 + ctrl[0].1 * 77 + 5)))
                    var i = 10
                    while i < pts.count - 6 {
                        let p = pts[i], q = pts[i + 3]
                        let ang = atan2(q.y - p.y, q.x - p.x)
                        let side: Double = (i / 11) % 2 == 0 ? 1 : -1
                        let la = ang + side * (0.75 + lg.next() * 0.3)
                        let ln = (0.07 + lg.next() * 0.05) * u
                        l.fill(SwirlArt.leaf(p, la, ln, ln * 0.28), with: .color((strong ? ink : soft).opacity(strong ? 0.5 : 0.55)))
                        i += 11
                    }
                    if strong {
                        let m = sp[sp.count / 2]
                        let tr = SwirlArt.catmull([m, CGPoint(x: m.x + 0.08 * W, y: m.y - 0.05 * H),
                                                   CGPoint(x: m.x + 0.17 * W, y: m.y - 0.02 * H),
                                                   CGPoint(x: m.x + 0.22 * W, y: m.y + 0.05 * H)])
                        var acc = 0.0, last = tr[0], n = 0.0
                        for p in tr {
                            acc += hypot(p.x - last.x, p.y - last.y); last = p
                            let r = max(0.011 * u - 0.0001 * u * n, 0.0025 * u)
                            if acc > r * 2.6 {
                                acc = 0; n += 1
                                l.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(ink.opacity(0.7)))
                            }
                        }
                    }
                }
                for (cx, cy, R, rt, seed) in [(0.02, 0.66, 0.30, 0.35, 3), (0.14, 0.27, 0.17, -0.4, 9), (0.05, 0.95, 0.20, 0.8, 15)] {
                    SwirlArt.flower(&l, c: P(cx, cy), R: R * u, rotation: rt, seed: UInt32(seed), ink: ink, soft: soft)
                }
            }
        }
        .compositingGroup()
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .black.opacity(0.35), location: 0.7),
                                     .init(color: .clear, location: 0.88)], startPoint: .leading, endPoint: .trailing))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    struct LCG {
        var s: UInt32
        init(_ seed: UInt32) { s = seed }
        mutating func next() -> Double {
            s = s &* 1664525 &+ 1013904223
            return Double(s) / 4294967296.0
        }
    }

    static func catmull(_ pts: [CGPoint], n: Int = 14) -> [CGPoint] {
        var out: [CGPoint] = []
        let P = [pts[0]] + pts + [pts[pts.count - 1]]
        for i in 1..<(P.count - 2) {
            let p0 = P[i - 1], p1 = P[i], p2 = P[i + 1], p3 = P[i + 2]
            for k in 0..<n {
                let t = Double(k) / Double(n), t2 = t * t, t3 = t2 * t
                func f(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: f(p0.x, p1.x, p2.x, p3.x), y: f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    static func spiral(end: CGPoint, tangent: CGPoint, r0: Double, turns: Double, dir: Double, n: Int = 60) -> [CGPoint] {
        let tl = hypot(tangent.x, tangent.y)
        let tx = tangent.x / tl, ty = tangent.y / tl
        let nx = -ty * dir, ny = tx * dir
        let cx = end.x + nx * r0, cy = end.y + ny * r0
        let th0 = atan2(end.y - cy, end.x - cx)
        return (1...n).map { (i: Int) -> CGPoint in
            let t = Double(i) / Double(n)
            let r: Double = r0 * pow(1 - 0.9 * t, 1.15)
            let th: Double = th0 + dir * turns * 2 * Double.pi * t
            return CGPoint(x: cx + r * cos(th), y: cy + r * sin(th))
        }
    }

    static func ribbon(_ pts: [CGPoint], _ w0: Double, _ w1: Double) -> Path {
        let n = pts.count
        var L: [CGPoint] = [], R: [CGPoint] = []
        for (i, p) in pts.enumerated() {
            let a = pts[max(i - 1, 0)], b = pts[min(i + 1, n - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let d = max(hypot(dx, dy), 0.0001)
            let nx = -dy / d, ny = dx / d
            let w = (w0 + (w1 - w0) * Double(i) / Double(n - 1)) / 2
            L.append(CGPoint(x: p.x + nx * w, y: p.y + ny * w))
            R.append(CGPoint(x: p.x - nx * w, y: p.y - ny * w))
        }
        var path = Path()
        path.addLines(L + R.reversed())
        path.closeSubpath()
        return path
    }

    static func leaf(_ base: CGPoint, _ ang: Double, _ length: Double, _ width: Double) -> Path {
        let tip = CGPoint(x: base.x + cos(ang) * length, y: base.y + sin(ang) * length)
        let nx = -sin(ang), ny = cos(ang)
        let mid = CGPoint(x: base.x + cos(ang) * length * 0.5, y: base.y + sin(ang) * length * 0.5)
        var p = Path()
        p.move(to: base)
        p.addQuadCurve(to: tip, control: CGPoint(x: mid.x + nx * width, y: mid.y + ny * width))
        p.addQuadCurve(to: base, control: CGPoint(x: mid.x - nx * width, y: mid.y - ny * width))
        return p
    }

    static func flower(_ l: inout GraphicsContext, c: CGPoint, R: Double, rotation: Double, seed: UInt32, ink: Color, soft: Color) {
        let lw = max(1, 0.012 * R)
        for k in 0..<5 {
            let ang = rotation + Double(k) * 2 * Double.pi / 5
            var petal = Path()
            petal.move(to: CGPoint(x: 0.1 * R, y: 0))
            petal.addCurve(to: CGPoint(x: 0.93 * R, y: -0.08 * R), control1: CGPoint(x: 0.15 * R, y: -0.9 * R), control2: CGPoint(x: 1.05 * R, y: -0.85 * R))
            petal.addLine(to: CGPoint(x: 0.86 * R, y: 0))
            petal.addLine(to: CGPoint(x: 0.93 * R, y: 0.08 * R))
            petal.addCurve(to: CGPoint(x: 0.1 * R, y: 0), control1: CGPoint(x: 1.05 * R, y: 0.85 * R), control2: CGPoint(x: 0.15 * R, y: 0.9 * R))
            petal.closeSubpath()
            let tf = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: ang)
            let pp = petal.applying(tf)
            l.fill(pp, with: .color(soft.opacity(0.78)))
            l.stroke(pp, with: .color(ink.opacity(0.9)), lineWidth: lw)
            for v in [-0.35, -0.17, 0.0, 0.17, 0.35] {
                let a2 = ang + v * 0.8
                let r1 = (0.62 + 0.08 * (1 - abs(v))) * R
                var vein = Path()
                vein.move(to: CGPoint(x: c.x + cos(a2) * 0.28 * R, y: c.y + sin(a2) * 0.28 * R))
                vein.addLine(to: CGPoint(x: c.x + cos(a2) * r1, y: c.y + sin(a2) * r1))
                l.stroke(vein, with: .color(ink.opacity(0.75)), lineWidth: lw)
            }
            var g = LCG(seed + UInt32(k))
            for _ in 0..<26 {
                let rr = 0.62 + g.next() * 0.3, aa = (g.next() - 0.5) * 0.9
                let x = c.x + cos(ang + aa) * rr * R, y = c.y + sin(ang + aa) * rr * R
                let d = 0.014 * R
                l.fill(Path(ellipseIn: CGRect(x: x - d, y: y - d, width: d * 2, height: d * 2)), with: .color(ink.opacity(0.7)))
            }
        }
        let cr = 0.2 * R
        let centre = Path(ellipseIn: CGRect(x: c.x - cr, y: c.y - cr, width: cr * 2, height: cr * 2))
        l.fill(centre, with: .color(.white.opacity(0.7)))
        l.stroke(centre, with: .color(ink.opacity(0.9)), lineWidth: max(1, 0.02 * R))
    }
}

/// Full-screen backdrop for the current theme.
struct ThemedBackground: View {
    @Environment(\.palette) private var palette
    var body: some View {
        ZStack {
            if let art = palette.art {
                LinearGradient(colors: [art.bg0, art.bg1], startPoint: .top, endPoint: .bottom)
                SwirlArt(ink: art.ink, soft: art.soft)
            } else {
                palette.background
            }
        }
        .ignoresSafeArea()
    }
}
