import SwiftUI

/// The notch's outline: the top corners flare out into the screen's edge, like the real notch, and the bottom ones are rounded.
struct NotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(flare, radius) }
        set { flare = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path { Path(Self.outline(in: rect, flare: flare, radius: radius)) }

    /// In y-down coordinates: the top edge spans the whole width, the sides start `flare` points in.
    static func outline(in rect: CGRect, flare f: CGFloat, radius r: CGFloat) -> CGPath {
        let f = min(f, rect.width / 4, rect.height / 2)
        let r = min(r, rect.width / 2 - f, rect.height - f)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f, y: rect.minY + f), control: CGPoint(x: rect.minX + f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + f, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + f + r, y: rect.maxY), control: CGPoint(x: rect.minX + f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f - r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - f, y: rect.maxY - r), control: CGPoint(x: rect.maxX - f, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
