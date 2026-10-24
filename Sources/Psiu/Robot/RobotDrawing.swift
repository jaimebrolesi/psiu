import PsiuCore
import SwiftUI

/// The robot's look, picked by the Store from the sessions' states.
enum RobotColor { case red, burnt, yellow, blue, backgroundBlue, green, dimGreen, gray }

/// Builds a path from SVG path data with absolute M, C and Z commands.
private func svgPath(_ d: String) -> Path {
    let tokens = d.map { $0.isLetter ? " \($0) " : String($0) }.joined().split(separator: " ")
    var p = Path(), i = 0, command: Character = "M"
    func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
    func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter {
            command = c; i += 1
            if command == "Z" { p.closeSubpath() }
            continue
        }
        switch command {
        case "M": p.move(to: point())
        case "C":
            let c1 = point(), c2 = point()
            p.addCurve(to: point(), control1: c1, control2: c2)
        default: i += 1
        }
    }
    return p
}

/// The eyes on fire of the panic state, on the 60 x 46 grid.
private enum Flames {
    static let left = svgPath("M20.5 12 C24.5 17.5 28.2 21 28.2 26.8 C28.2 31.2 24.8 34 20.5 34 C16.2 34 12.8 31.2 12.8 26.8 C12.8 23 15 20.8 16.4 18.4 C17 21 18 22.4 19.2 22.8 C18.8 19.2 19.3 15.6 20.5 12 Z")
    static let leftCore = svgPath("M20.5 20 C22.8 23.2 24.8 25.2 24.8 28.4 C24.8 31.2 22.8 33 20.5 33 C18.2 33 16.2 31.2 16.2 28.4 C16.2 25.8 18.2 23.4 20.5 20 Z")
    static let right = svgPath("M39.5 12 C40.7 15.6 41.2 19.2 40.8 22.8 C42 22.4 43 21 43.6 18.4 C45 20.8 47.2 23 47.2 26.8 C47.2 31.2 43.8 34 39.5 34 C35.2 34 31.8 31.2 31.8 26.8 C31.8 21 35.5 17.5 39.5 12 Z")
    static let rightCore = svgPath("M39.5 20 C41.8 23.4 43.8 25.8 43.8 28.4 C43.8 31.2 41.8 33 39.5 33 C37.2 33 35.2 31.2 35.2 28.4 C35.2 25.2 37.2 23.2 39.5 20 Z")
}

/// Mixes two 0xRRGGBB colors, from a (f = 0) to b (f = 1).
private func mix(_ a: UInt32, _ b: UInt32, _ f: Double, alpha: Double) -> Color {
    func channel(_ c: UInt32, _ shift: UInt32) -> Double { Double((c >> shift) & 0xFF) / 255 }
    func blend(_ shift: UInt32) -> Double { channel(a, shift) + (channel(b, shift) - channel(a, shift)) * f }
    return Color(.sRGB, red: blend(16), green: blend(8), blue: blend(0), opacity: alpha)
}

private func phase(_ t: Double, _ period: Double) -> Double {
    t.truncatingRemainder(dividingBy: period) / period
}

private func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
                      scaleY: CGFloat = 1, dx: CGFloat = 0) -> Path {
    let nh = h * scaleY
    let cy = y + h / 2
    return Path(roundedRect: CGRect(x: x + dx, y: cy - nh / 2, width: w, height: nh),
                cornerRadius: min(r, nh / 2))
}

private func headShape() -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 30, y: 6.5))
    p.addCurve(to: CGPoint(x: 55, y: 25), control1: CGPoint(x: 46, y: 6.5), control2: CGPoint(x: 55, y: 13))
    p.addCurve(to: CGPoint(x: 30, y: 43), control1: CGPoint(x: 55, y: 37), control2: CGPoint(x: 46, y: 43))
    p.addCurve(to: CGPoint(x: 5, y: 25), control1: CGPoint(x: 14, y: 43), control2: CGPoint(x: 5, y: 37))
    p.addCurve(to: CGPoint(x: 30, y: 6.5), control1: CGPoint(x: 5, y: 13), control2: CGPoint(x: 14, y: 6.5))
    p.closeSubpath()
    return p
}

private func visorShape() -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 30, y: 9.2))
    p.addCurve(to: CGPoint(x: 52.3, y: 25), control1: CGPoint(x: 44, y: 9.2), control2: CGPoint(x: 52.3, y: 14.8))
    p.addCurve(to: CGPoint(x: 30, y: 40.3), control1: CGPoint(x: 52.3, y: 35.2), control2: CGPoint(x: 44, y: 40.3))
    p.addCurve(to: CGPoint(x: 7.7, y: 25), control1: CGPoint(x: 16, y: 40.3), control2: CGPoint(x: 7.7, y: 35.2))
    p.addCurve(to: CGPoint(x: 30, y: 9.2), control1: CGPoint(x: 7.7, y: 14.8), control2: CGPoint(x: 16, y: 9.2))
    p.closeSubpath()
    return p
}

/// Eyes drooping with tiredness (heavy context, purple Psiu), with a drop of sweat on the side.
private func tiredEyes(_ g: inout GraphicsContext, _ led: Color, dx: CGFloat, _ t: Double,
                       eyes: Bool = true, drop: Bool = true) {
    if eyes {
        let droop = CGFloat(1 - 0.1 * (1 - cos(2 * .pi * t / 2.6)) / 2)
        for (cx, angle) in [(CGFloat(20.5), -7.0), (CGFloat(39.5), 7.0)] {
            var gg = g
            gg.translateBy(x: cx + dx, y: 26.5)
            gg.rotate(by: .degrees(angle))
            gg.fill(pill(-6.5, -5, 13, 10, 4.4, scaleY: droop), with: .color(led))
        }
    }
    guard drop else { return }
    let p = phase(t, 1.6)
    let y = CGFloat(-2 + 11 * p)
    let fade = p < 0.2 ? p / 0.2 : (p > 0.8 ? (1 - p) / 0.2 : 1)
    var drop = Path()
    drop.move(to: CGPoint(x: 53, y: 7 + y))
    drop.addCurve(to: CGPoint(x: 57, y: 14.8 + y), control1: CGPoint(x: 56, y: 11 + y), control2: CGPoint(x: 57, y: 13 + y))
    drop.addCurve(to: CGPoint(x: 53, y: 18.4 + y), control1: CGPoint(x: 57, y: 17 + y), control2: CGPoint(x: 55.2, y: 18.4 + y))
    drop.addCurve(to: CGPoint(x: 49, y: 14.8 + y), control1: CGPoint(x: 50.8, y: 18.4 + y), control2: CGPoint(x: 49, y: 17 + y))
    drop.addCurve(to: CGPoint(x: 53, y: 7 + y), control1: CGPoint(x: 49, y: 13 + y), control2: CGPoint(x: 50, y: 11 + y))
    g.fill(drop, with: .color(Color(hex: 0xEEEDFE, alpha: fade)))
}

/// The pieces Core Animation moves on their own (see RobotLayerView). `.all` draws the whole robot, moving,
/// as the icon, the installer and the docs need; the other parts are drawn still, at the head's resting place.
enum RobotPart { case all, body, eyes, drop, embers, smoke, particles, relief }

/// Relief after you answer, out of yellow or red: eyes shut, a breath in, the head sinking as the
/// air goes out in a puff, then settling into the new state, whose color the shell takes on along the way.
struct RobotRelief: Equatable {
    var from: RobotColor
    var progress: Double
    static let duration = 2.0
    /// The eyes stay shut until here, then open into the new state's.
    static let eyesOpen = 0.75
}

/// Shell and LED colors per state.
func robotPalette(_ color: RobotColor, _ tired: Bool) -> (shellHex: UInt32, shellAlpha: Double, led: Color) {
    let shellHex: UInt32, shellAlpha: Double, led: Color
    switch color {
    case .red: shellHex = 0xF09595; shellAlpha = 1; led = Color(hex: 0xFFD27A)
    case .burnt: shellHex = 0x554A43; shellAlpha = 1; led = Color(hex: 0xD3D1C7)
    case .blue where tired, .backgroundBlue where tired:   // heavy work: purple and tired
        shellHex = 0xAFA9EC; shellAlpha = 1; led = Color(hex: 0xCECBF6)
    case .blue, .backgroundBlue: shellHex = 0x85B7EB; shellAlpha = 1; led = Color(hex: 0xA9D2FF)
    case .yellow: shellHex = 0xFAC775; shellAlpha = 1; led = Color(hex: 0xFFD27A)
    case .green: shellHex = 0xC0DD97; shellAlpha = 1; led = Color(hex: 0xC7EE8F)
    case .dimGreen: shellHex = 0xC0DD97; shellAlpha = 0.5; led = Color(hex: 0xC7EE8F, alpha: 0.5)
    case .gray: shellHex = 0x888780; shellAlpha = 1; led = Color(hex: 0xD3D1C7)
    }
    return (shellHex, shellAlpha, led)
}

/// Head movement, on the 60 x 46 grid: sideways and down, and the tilt in degrees around (30, 25).
func headMotion(_ color: RobotColor, peeking: Bool, _ t: Double) -> (sway: Double, dy: Double, tilt: Double) {
    var dy = 0.0, tilt = 0.0, sway = 0.0
    switch color {
    case .red:
        let w = 2 * .pi * t / 0.32
        sway = 1.4 * sin(w)
        tilt = 4 * sin(w + .pi / 2)
    case .burnt:
        tilt = -5 + sin(2 * .pi * t / 3)
    case .yellow:
        let w = sin(2 * .pi * t / 0.9)
        tilt = 5 * w
        dy = -3 * abs(w)
    case .green:
        let p = phase(t, 1.5)
        dy = p < 0.6 ? -5 * sin(.pi * p / 0.6) : 0
    case .gray:
        dy = 1.5 * (1 - cos(2 * .pi * t / 3.2)) / 2
    case .backgroundBlue where peeking:
        let p = phase(t, 5)
        // rests at the bottom, rises between 38% and 48%, stays up until 68%, goes down by 78%
        let rise: Double = p < 0.38 ? 0 : p < 0.48 ? (1 - cos(.pi * (p - 0.38) / 0.10)) / 2 : p < 0.68 ? 1 : p < 0.78 ? (1 + cos(.pi * (p - 0.68) / 0.10)) / 2 : 0
        dy = 21 - 4.5 * rise
    default:
        break
    }
    return (sway, dy, tilt)
}

/// Relief: the head rises with the breath in, sinks as it goes out and settles (down on the grid); out of panic,
/// the shaking dies down first (extra tilt in degrees).
func reliefMotion(_ r: RobotRelief, _ t: Double) -> (dy: Double, tilt: Double) {
    let p = r.progress
    let dy: Double
    if p < 0.18 {
        dy = -2 * sin(.pi / 2 * p / 0.18)
    } else if p < 0.6 {
        dy = -2 + 5 * (1 - cos(.pi * (p - 0.18) / 0.42)) / 2
    } else {
        dy = 3 * (1 + cos(.pi * (p - 0.6) / 0.4)) / 2
    }
    let tilt = r.from == .red ? 4 * sin(2 * .pi * t / 0.32 + .pi / 2) * max(0, 1 - p / 0.35) : 0
    return (dy, tilt)
}

/// Reviving, when you answer a burnt Psiu: it shakes off the soot and comes out of a curtain of smoke.
enum RobotRevival {
    static let duration = 1.5
    /// The shake settles by here (the first 0.8 s).
    static let shakeEnds = 0.8 / duration
}

/// Reviving: shakes off the soot at 10 Hz, settling down to still (extra tilt in degrees).
func revivalShake(_ p: Double, _ t: Double) -> Double {
    6 * sin(2 * .pi * 10 * t) * max(0, 1 - p / RobotRevival.shakeEnds)
}

/// How far the LED eyes scan sideways, on the grid.
func eyeShift(_ color: RobotColor, peeking: Bool, _ t: Double) -> CGFloat {
    switch color {
    case .blue: return CGFloat(3 * sin(2 * .pi * t / 1.3))
    case .backgroundBlue where peeking: return CGFloat(2.6 * sin(2 * .pi * t / 4))
    case .backgroundBlue: return CGFloat(3 * sin(2 * .pi * t / 4))
    default: return 0
    }
}

func drawRobot(_ g: inout GraphicsContext, _ size: CGSize, _ color: RobotColor, _ tired: Bool, _ t: Double,
                          peeking: Bool = false, bandaged: Bool = false, revival: Double? = nil, relief: RobotRelief? = nil,
                          part: RobotPart = .all) {
    let s = min(size.width / 60, size.height / 46)
    g.translateBy(x: (size.width - 60 * s) / 2, y: (size.height - 46 * s) / 2)
    g.scaleBy(x: s, y: s)
    let whole = part == .all
    if peeking && whole { g.clip(to: Path(CGRect(x: 0, y: 0, width: 60, height: 46))) }

    let (shellHex, shellAlpha, led) = robotPalette(color, tired)
    // Reviving, the shell goes from burnt to the new state's color.
    // Relieved, from yellow or red.
    let shell = revival.map { mix(0x554A43, shellHex, $0, alpha: 1 + (shellAlpha - 1) * $0) }
        ?? relief.map { mix(robotPalette($0.from, false).shellHex, shellHex, $0.progress, alpha: 1 + (shellAlpha - 1) * $0.progress) }
        ?? Color(hex: shellHex, alpha: shellAlpha)

    if whole {
        var (sway, dy, tilt) = headMotion(color, peeking: peeking, t)
        if let p = revival { tilt += revivalShake(p, t) }
        if let r = relief {
            let (rdy, rtilt) = reliefMotion(r, t)
            dy += rdy
            tilt += rtilt
        }
        g.translateBy(x: 30 + sway, y: 25 + dy)
        g.rotate(by: .degrees(tilt))
        g.translateBy(x: -30, y: -25)
    }

    if whole || part == .body { drawBody(&g, s, color, bandaged, shell) }
    let eyesShut = relief.map { $0.progress < RobotRelief.eyesOpen } ?? false
    if (whole && !eyesShut) || part == .eyes || part == .drop || part == .embers || part == .smoke {
        drawEyes(&g, color, tired, peeking, t, led, dx: whole ? eyeShift(color, peeking: peeking, t) : 0, part: part)
    }
    if (whole || part == .particles), let p = revival { drawSmokeCurtain(&g, p) }
    if (whole || part == .relief), let r = relief {
        if eyesShut { drawRelievedEyes(&g, led) }
        drawPuff(&g, r.progress)
    }
}

/// Shell, soot streaks, visor and headband.
private func drawBody(_ g: inout GraphicsContext, _ s: CGFloat, _ color: RobotColor, _ bandaged: Bool, _ shell: Color) {
    g.fill(headShape(), with: .color(shell))
    if color == .burnt && s > 1 {   // soot streaks, only at large sizes
        var soot = Path()
        for (a, b) in [((9.5, 13.5), (13.5, 9.8)), ((33.0, 7.2), (38.5, 8.4)), ((50.8, 31.0), (53.4, 27.0))] {
            soot.move(to: CGPoint(x: a.0, y: a.1)); soot.addLine(to: CGPoint(x: b.0, y: b.1))
        }
        g.stroke(soot, with: .color(Color(hex: 0x2C2622)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
    }
    g.fill(visorShape(), with: .color(Color(hex: 0x141414)))
    if bandaged && color == .green {   // compacted along the way: a purple headband
        var band = g
        band.clip(to: headShape())
        band.fill(Path(CGRect(x: 0, y: 4, width: 60, height: 11)), with: .color(Color(hex: 0xAFA9EC)))
        var stripes = Path()
        stripes.move(to: CGPoint(x: 0, y: 8)); stripes.addLine(to: CGPoint(x: 60, y: 11.5))
        stripes.move(to: CGPoint(x: 0, y: 11.5)); stripes.addLine(to: CGPoint(x: 60, y: 8))
        band.stroke(stripes, with: .color(Color(hex: 0x8F88D8)), lineWidth: 0.9)
        var ends = Path()
        ends.move(to: CGPoint(x: 52.5, y: 10.5)); ends.addQuadCurve(to: CGPoint(x: 59.5, y: 5.5), control: CGPoint(x: 57, y: 7))
        ends.move(to: CGPoint(x: 52.5, y: 12)); ends.addQuadCurve(to: CGPoint(x: 59, y: 17.5), control: CGPoint(x: 57, y: 14))
        g.stroke(ends, with: .color(Color(hex: 0xAFA9EC)), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
    }
}

/// LED eyes, and what goes with them: the sweat drop, the embers and the smoke.
private func drawEyes(_ g: inout GraphicsContext, _ color: RobotColor, _ tired: Bool, _ peeking: Bool, _ t: Double,
                      _ led: Color, dx: CGFloat, part: RobotPart) {
    let whole = part == .all
    let eyes = whole || part == .eyes
    if !eyes && part != .drop && part != .embers && part != .smoke { return }
    switch color {
    case .red:   // panic: eyes on fire, flickering from the base
        guard eyes else { break }
        for (flame, core, cx, offset) in [(Flames.left, Flames.leftCore, 20.5, 0.0), (Flames.right, Flames.rightCore, 39.5, Double.pi)] {
            let w = 2 * .pi * t / 0.42 + offset
            var gg = g
            gg.translateBy(x: cx, y: 34)
            gg.concatenate(CGAffineTransform(a: 1, b: 0, c: tan(5 * cos(w) * .pi / 180), d: 1.02 + 0.10 * sin(w), tx: 0, ty: 0))
            gg.translateBy(x: -cx, y: -34)
            gg.fill(flame, with: .color(Color(hex: 0xF0703C)))
            gg.translateBy(x: cx, y: 34)
            gg.scaleBy(x: 1, y: 0.975 + 0.175 * sin(2 * .pi * t / 0.3 + offset))
            gg.translateBy(x: -cx, y: -34)
            gg.fill(core, with: .color(led))
        }

    case .burnt:   // burnt out: X eyes, embers and smoke
        if eyes {
            var x = Path()
            for (a, b) in [((15.5, 20.0), (25.5, 30.0)), ((25.5, 20.0), (15.5, 30.0)), ((34.5, 20.0), (44.5, 30.0)), ((44.5, 20.0), (34.5, 30.0))] {
                x.move(to: CGPoint(x: a.0, y: a.1)); x.addLine(to: CGPoint(x: b.0, y: b.1))
            }
            g.stroke(x, with: .color(led), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
        for (x, y, offset) in [(9.0, 17.0, 0.0), (50.0, 35.0, Double.pi)] where whole || part == .embers {
            let glow = 0.625 + 0.375 * sin(2 * .pi * t / 1.4 + offset)
            g.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Color(hex: 0xF0703C, alpha: glow)))
        }
        for (i, x0) in [24.0, 38.0, 31.0].enumerated() where whole || part == .smoke {
            let p = phase(t + Double(i) * 2.6 / 3, 2.6)
            let r = 3 * (0.6 + 0.8 * p)
            let c = CGPoint(x: x0 + 3 * p, y: 8 - 16 * p)
            g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(Color(hex: 0x8E8C86, alpha: 0.7 * sin(.pi * p))))
        }

    case .blue:   // focused, scanning from side to side
        if tired { tiredEyes(&g, led, dx: dx, t, eyes: eyes, drop: whole || part == .drop); break }
        guard eyes else { break }
        g.fill(pill(14, 18.4, 13, 12.8, 5, dx: dx), with: .color(led))
        g.fill(pill(33, 18.4, 13, 12.8, 5, dx: dx), with: .color(led))

    case .backgroundBlue where peeking:   // sunk into the notch, peeking over the edge
        if tired { tiredEyes(&g, led, dx: dx, t, eyes: eyes, drop: whole || part == .drop); break }
        guard eyes else { break }
        let p = phase(t, 5)
        let blink: CGFloat = (p > 0.90 && p < 0.94) ? 0.1 : 1
        g.fill(pill(14, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))
        g.fill(pill(33, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))

    case .backgroundBlue:   // panel open: whole head, scanning slowly and blinking
        if tired { tiredEyes(&g, led, dx: dx, t, eyes: eyes, drop: whole || part == .drop); break }
        guard eyes else { break }
        let p = phase(t, 4)
        let blink: CGFloat = (p > 0.9 && p < 0.95) ? 0.12 : 1
        g.fill(pill(14, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))
        g.fill(pill(33, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))

    case .yellow:   // eyes and exclamation mark alternating
        guard eyes else { break }
        if Int(t / 0.8) % 2 == 0 {
            g.fill(pill(14, 16, 13, 17.4, 5.6), with: .color(led))
            g.fill(pill(33, 16, 13, 17.4, 5.6), with: .color(led))
        } else {
            g.fill(pill(26, 13, 8, 15.2, 4), with: .color(led))
            g.fill(Path(ellipseIn: CGRect(x: 26, y: 29.4, width: 8, height: 8)), with: .color(led))
        }

    case .green:   // smiling
        guard eyes else { break }
        var arcs = Path()
        arcs.move(to: CGPoint(x: 15, y: 29)); arcs.addQuadCurve(to: CGPoint(x: 26, y: 29), control: CGPoint(x: 20.5, y: 18))
        arcs.move(to: CGPoint(x: 34, y: 29)); arcs.addQuadCurve(to: CGPoint(x: 45, y: 29), control: CGPoint(x: 39.5, y: 18))
        g.stroke(arcs, with: .color(led), style: StrokeStyle(lineWidth: 4.6, lineCap: .round))

    case .dimGreen:   // half-closed, blinking slowly
        guard eyes else { break }
        let p = phase(t, 5)
        let blink: CGFloat = (p > 0.9 && p < 0.96) ? 0.12 : 1
        g.fill(pill(14, 21.6, 13, 8.6, 4, scaleY: blink), with: .color(led))
        g.fill(pill(33, 21.6, 13, 8.6, 4, scaleY: blink), with: .color(led))

    case .gray:   // sleeping: Z z lighting up in turn
        guard eyes else { break }
        let wave = cos(2 * .pi * t / 2.4)
        var zg = Path()
        zg.addLines([CGPoint(x: 15, y: 17), CGPoint(x: 26, y: 17), CGPoint(x: 15, y: 32), CGPoint(x: 26, y: 32)])
        var zp = Path()
        zp.addLines([CGPoint(x: 35, y: 22), CGPoint(x: 44, y: 22), CGPoint(x: 35, y: 32), CGPoint(x: 44, y: 32)])
        g.stroke(zg, with: .color(led.opacity(0.675 + 0.325 * wave)),
                 style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        g.stroke(zp, with: .color(led.opacity(0.675 - 0.325 * wave)),
                 style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
    }
}

/// Reviving: a curtain of smoke covers the shell, then rises, spreads and thins out, revealing the new color.
private func drawSmokeCurtain(_ g: inout GraphicsContext, _ p: Double) {
    let puffs: [(x: Double, y: Double, r: Double, delay: Double)] = [
        (9, 31, 7, 0.00), (20, 37, 8, 0.06), (30, 33, 9, 0.02), (40, 37, 8, 0.08), (51, 31, 7, 0.04),
        (14, 19, 7, 0.12), (30, 15, 8, 0.15), (46, 19, 7, 0.10),
    ]
    // One soft cloud: puffs with soft edges (gradients draw the same on every Mac, unlike a blur) in one layer.
    let smoke = Color(hex: 0x9A978F)
    let soft = Gradient(stops: [.init(color: smoke, location: 0), .init(color: smoke, location: 0.45),
                                .init(color: smoke.opacity(0), location: 1)])
    g.drawLayer { cloud in
        cloud.opacity = 0.9 * pow(1 - p, 1.3)
        for c in puffs {
            let q = max(0, min(1, (p - c.delay) / 0.85))
            let eased = 1 - (1 - q) * (1 - q)
            let r = c.r * (0.9 + 0.9 * eased)
            let center = CGPoint(x: c.x + (c.x - 30) * 0.35 * eased, y: c.y - 24 * eased)
            let edge = r * 1.35
            cloud.fill(Path(ellipseIn: CGRect(x: center.x - edge, y: center.y - edge, width: 2 * edge, height: 2 * edge)),
                       with: .radialGradient(soft, center: center, startRadius: 0, endRadius: edge))
        }
    }
}

/// Relief: eyes shut in a content curve.
private func drawRelievedEyes(_ g: inout GraphicsContext, _ led: Color) {
    var arcs = Path()
    arcs.move(to: CGPoint(x: 15, y: 25)); arcs.addQuadCurve(to: CGPoint(x: 26, y: 25), control: CGPoint(x: 20.5, y: 31))
    arcs.move(to: CGPoint(x: 34, y: 25)); arcs.addQuadCurve(to: CGPoint(x: 45, y: 25), control: CGPoint(x: 39.5, y: 31))
    g.stroke(arcs, with: .color(led), style: StrokeStyle(lineWidth: 4, lineCap: .round))
}

/// Relief: two puffs of air leave the side of the head as it breathes out, growing and fading.
private func drawPuff(_ g: inout GraphicsContext, _ p: Double) {
    for (i, delay) in [0.0, 0.12].enumerated() {
        let q = (p - 0.25 - delay) / 0.5
        guard q > 0, q < 1 else { continue }
        let r = 2.4 + 2.6 * q
        let c = CGPoint(x: 54 + 8 * q + 2 * Double(i), y: 36 + 2 * q - 4 * Double(i))
        g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
               with: .color(Color(hex: 0xEEEDFE, alpha: 0.85 * sin(.pi * min(1, q * 1.6)))))
    }
}
