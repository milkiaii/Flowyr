import SwiftUI

/// PS Vita-style backdrop: deep blue gradient with slowly rising translucent bubbles.
/// Pauses the animated backdrop while a system picker is open.
final class BackdropMotion: ObservableObject {
    static let shared = BackdropMotion()
    @Published var paused = false
}

struct VitaBubbles: View {
    @ObservedObject private var motion = BackdropMotion.shared
    private struct Bubble { let x, size, speed, phase, drift, alpha: Double }
    private static let bubbles: [Bubble] = {
        var s: UInt32 = 20111217
        func r() -> Double { s = s &* 1664525 &+ 1013904223; return Double(s) / 4294967296.0 }
        return (0..<26).map { _ in
            Bubble(x: r(), size: 0.02 + r() * r() * 0.16, speed: 0.012 + r() * 0.022,
                   phase: r(), drift: 0.01 + r() * 0.03, alpha: 0.10 + r() * 0.18)
        }
    }()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: motion.paused)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                let W = size.width, H = size.height
                for b in Self.bubbles {
                    let cycle = (t * b.speed + b.phase).truncatingRemainder(dividingBy: 1)
                    let r = b.size * min(W, H) * 0.9
                    let x = (b.x + sin(t * 0.15 + b.phase * 20) * b.drift) * W
                    let y = H + r - cycle * (H + r * 2)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    let fade = min(1, cycle * 6, (1 - cycle) * 6)
                    ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                        Gradient(colors: [.white.opacity(0.02 * fade), .white.opacity(b.alpha * 0.5 * fade)]),
                        center: CGPoint(x: x, y: y), startRadius: r * 0.55, endRadius: r))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(b.alpha * 1.3 * fade)), lineWidth: 1)
                    let hl = CGRect(x: x - r * 0.55, y: y - r * 0.62, width: r * 0.5, height: r * 0.3)
                    ctx.fill(Path(ellipseIn: hl), with: .color(.white.opacity(b.alpha * 1.1 * fade)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Full-screen backdrop for the current theme.
struct ThemedBackground: View {
    @Environment(\.palette) private var palette
    var body: some View {
        ZStack {
            if let backdrop = palette.backdrop {
                LinearGradient(stops: [.init(color: backdrop.top, location: 0),
                                       .init(color: backdrop.mid, location: 0.55),
                                       .init(color: backdrop.bottom, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                VitaBubbles()
            } else {
                palette.background
            }
        }
        .ignoresSafeArea()
    }
}
