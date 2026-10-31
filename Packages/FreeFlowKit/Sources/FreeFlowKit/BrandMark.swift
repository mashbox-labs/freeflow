import SwiftUI

/// The MASHBOX mark (box with the orange slash, from mashbox.gg/favicon.svg), optionally with sound coming out.
public struct BrandMark: View {
    var withSound: Bool
    var animating: Bool
    public init(withSound: Bool = true, animating: Bool = false) {
        self.withSound = withSound
        self.animating = animating
    }

    public var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                BoxHalf(left: true, shift: withSound ? 4 : 0).fill(Palette.fg, style: FillStyle(eoFill: true))
                BoxHalf(left: false, shift: withSound ? 4 : 0).fill(Palette.fg, style: FillStyle(eoFill: true))
                Slash(shift: withSound ? 4 : 0).fill(Palette.brand)
                if withSound {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !animating)) { context in
                        let t = context.date.timeIntervalSinceReferenceDate
                        ForEach(0..<3, id: \.self) { i in
                            let pulse = animating ? 0.55 + 0.45 * abs(sin(t * 3 + Double(i) * 0.7)) : 1
                            SoundArc(index: i)
                                .stroke(i == 2 ? Palette.brand : Palette.fg, style: StrokeStyle(lineWidth: s / 32 * 1.6, lineCap: .round))
                                .opacity(pulse)
                        }
                    }
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("MASHBOX")
    }
}

/// Coordinates follow the 32x32 favicon. With sound, the box shifts left to make room.
private func unit(_ rect: CGRect) -> (CGFloat, CGFloat, CGFloat) {
    let s = min(rect.width, rect.height) / 32
    return (s, rect.midX - 16 * s, rect.midY - 16 * s)
}

private struct BoxHalf: Shape {
    let left: Bool
    let shift: CGFloat
    func path(in rect: CGRect) -> Path {
        let (s, ox, oy) = unit(rect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: oy + y * s) }
        let dx: CGFloat = left ? -0.53 : 0.53, dy: CGFloat = left ? 1.51 : -1.51
        var ring = Path()
        ring.addRect(CGRect(origin: p(7 + dx - shift, 7 + dy), size: CGSize(width: 18 * s, height: 18 * s)))
        ring.addRect(CGRect(origin: p(11.5 + dx - shift, 11.5 + dy), size: CGSize(width: 9 * s, height: 9 * s)))
        var clip = Path()
        if left {
            clip.addLines([p(-32 - shift, -3.2), p(20.99 - shift, -3.2), p(7.41 - shift, 35.2), p(-32 - shift, 35.2)])
        } else {
            clip.addLines([p(24.59 - shift, -3.2), p(64, -3.2), p(64, 35.2), p(11.01 - shift, 35.2)])
        }
        clip.closeSubpath()
        return ring.intersection(clip, eoFill: true)
    }
}

private struct Slash: Shape {
    let shift: CGFloat
    func path(in rect: CGRect) -> Path {
        let (s, ox, oy) = unit(rect)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + (x - shift) * s, y: oy + y * s) }
        var path = Path()
        path.addLines([p(18.29, 4.44), p(21.89, 4.44), p(13.71, 27.56), p(10.11, 27.56)])
        path.closeSubpath()
        return path
    }
}

private struct SoundArc: Shape {
    let index: Int
    func path(in rect: CGRect) -> Path {
        let (s, ox, oy) = unit(rect)
        let r = (3 + CGFloat(index) * 2.6) * s
        let center = CGPoint(x: ox + 23.5 * s, y: oy + 16 * s)
        var path = Path()
        path.addArc(center: center, radius: r, startAngle: .degrees(-38), endAngle: .degrees(38), clockwise: false)
        return path
    }
}
