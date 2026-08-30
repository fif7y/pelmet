import SwiftUI

/// The app icon's P mark, drawn natively and animated: the two ghost dots tuck
/// into the P and return, on the same 5.7s cycle as the hero SVG and the
/// onboarding bar loop. Geometry mirrors `Pelmet-icon.svg` (1024 viewBox).
struct AnimatedAppIcon: View {
    var size: CGFloat = 96

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct DotPhases {
        var d1: CGFloat = 0  // 0 = home, 1 = tucked into the P
        var d2: CGFloat = 0
    }

    var body: some View {
        Group {
            if reduceMotion {
                icon(DotPhases())
            } else {
                KeyframeAnimator(initialValue: DotPhases()) { phases in
                    icon(phases)
                } keyframes: { _ in
                    // Hero timing: tuck over 8% of the cycle, hold to 46.5%,
                    // return by 54.5%, rest to 100%. d2 trails d1 by 0.05s.
                    KeyframeTrack(\.d1) {
                        CubicKeyframe(1, duration: 0.456)
                        CubicKeyframe(1, duration: 2.1945)
                        CubicKeyframe(0, duration: 0.456)
                        CubicKeyframe(0, duration: 2.5935)
                    }
                    KeyframeTrack(\.d2) {
                        CubicKeyframe(0, duration: 0.05)
                        CubicKeyframe(1, duration: 0.456)
                        CubicKeyframe(1, duration: 2.1945)
                        CubicKeyframe(0, duration: 0.456)
                        CubicKeyframe(0, duration: 2.5435)
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func icon(_ phases: DotPhases) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(Color(red: 0x68 / 255, green: 0x41 / 255, blue: 0xED / 255))
            Canvas { ctx, canvasSize in
                ctx.scaleBy(x: canvasSize.width / 1024, y: canvasSize.height / 1024)
                ctx.fill(Self.pPath, with: .color(.white))
                ctx.fill(Self.solidDot, with: .color(.white))
                drawGhost(Self.ghost1, into: &ctx, phase: phases.d1, travel: 77.5, restOpacity: 0.5)
                drawGhost(Self.ghost2, into: &ctx, phase: phases.d2, travel: 157, restOpacity: 0.15)
            }
        }
    }

    private func drawGhost(_ path: Path, into ctx: inout GraphicsContext, phase: CGFloat, travel: CGFloat, restOpacity: CGFloat) {
        var layer = ctx
        layer.translateBy(x: phase * travel, y: 0)
        layer.opacity = restOpacity * (1 - phase)
        layer.fill(path, with: .color(.white))
    }

    // MARK: - Geometry (icon SVG's 1024 space)

    private static let pPath: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 547.735, y: 309))
        p.addCurve(to: CGPoint(x: 711.751, y: 462.612),
                   control1: CGPoint(x: 657.283, y: 309),
                   control2: CGPoint(x: 711.751, y: 379.992))
        p.addCurve(to: CGPoint(x: 547.735, y: 616.224),
                   control1: CGPoint(x: 711.751, y: 548.292),
                   control2: CGPoint(x: 656.671, y: 615))
        p.addLine(to: CGPoint(x: 441.247, y: 616.224))
        p.addLine(to: CGPoint(x: 441.247, y: 697.4))
        p.addLine(to: CGPoint(x: 345.775, y: 697.4))
        p.addLine(to: CGPoint(x: 345.775, y: 528.708))
        p.addLine(to: CGPoint(x: 547.735, y: 528.708))
        p.addCurve(to: CGPoint(x: 616.279, y: 464.448),
                   control1: CGPoint(x: 593.635, y: 528.708),
                   control2: CGPoint(x: 616.279, y: 498.72))
        p.addCurve(to: CGPoint(x: 547.735, y: 399.576),
                   control1: CGPoint(x: 616.279, y: 430.176),
                   control2: CGPoint(x: 593.023, y: 399.576))
        p.addLine(to: CGPoint(x: 345.775, y: 399.576))
        p.addLine(to: CGPoint(x: 345.775, y: 309))
        p.closeSubpath()
        return p
    }()

    private static let solidDot = Path(ellipseIn: CGRect(x: 551.502 - 41.5, y: 463.492 - 41.5, width: 83, height: 83))

    /// Ghost dots are circles carved so they never overlap their neighbor
    /// (matches the moon shapes in the source SVG).
    private static let ghost1 = carvedDot(center: CGPoint(x: 474.007, y: 463.391), radius: 41.58,
                                          neighbor: CGPoint(x: 551.502, y: 463.492), clearance: 48.1)
    private static let ghost2 = carvedDot(center: CGPoint(x: 394.582, y: 463.391), radius: 41.58,
                                          neighbor: CGPoint(x: 474.007, y: 463.391), clearance: 49.3)

    private static func carvedDot(center: CGPoint, radius: CGFloat, neighbor: CGPoint, clearance: CGFloat) -> Path {
        let dot = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                           width: radius * 2, height: radius * 2), transform: nil)
        let carve = CGPath(ellipseIn: CGRect(x: neighbor.x - clearance, y: neighbor.y - clearance,
                                             width: clearance * 2, height: clearance * 2), transform: nil)
        return Path(dot.subtracting(carve))
    }
}
