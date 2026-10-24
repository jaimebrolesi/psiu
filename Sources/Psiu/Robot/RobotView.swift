import AppKit
import SwiftUI
import QuartzCore

// MARK: - Robot

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Robot head with LED eyes. Drawn on a 60 x 46 grid by drawRobot, animated by Core Animation
/// (see RobotLayerView), so the app itself does no work while the robot moves.
struct RobotView: NSViewRepresentable {
    let color: RobotColor
    var tired = false
    /// Background state with the panel closed: sunk into the notch, only the top half of the head shows.
    var peeking = false
    /// A compacted session finished: the green Psiu wears a purple headband.
    var bandaged = false
    /// Until when a burnt Psiu is shaking off the soot (0.8 s).
    var revivingUntil: Date? = nil
    /// Nobody can see the robot: stop animating it.
    var paused = false

    func makeNSView(context: Context) -> RobotLayerView { RobotLayerView() }

    func updateNSView(_ view: RobotLayerView, context: Context) {
        view.update(look: .init(color: color, tired: tired, peeking: peeking, bandaged: bandaged),
                    revivingUntil: revivingUntil, paused: paused)
    }
}

/// What the robot looks like; any change rebuilds its layers.
struct RobotLook: Equatable {
    var color: RobotColor
    var tired: Bool
    var peeking: Bool
    var bandaged: Bool
}

/// The robot as Core Animation layers: still images and strips of frames drawn once by drawRobot, moved and
/// played by the render server. Each moving piece loops on its own period, as in drawRobot:
///   root
///    └ stage: the robot at the size it was drawn for (clipped to the grid while peeking; scaled while resizing)
///       └ head: head movement (headMotion)
///       └ revive: the soot shake while reviving
///          ├ body: shell, visor, headband (+ the burnt shell fading out while reviving)
///          ├ eyeShift: the eyes scanning sideways (eyeShift)
///          │  └ eyes: frames of the LED eyes
///          └ drop, embers, smoke, particles: frames
final class RobotLayerView: NSView {
    /// Room around the grid, so smoke and soot can leave the head without being cut.
    static let margin: CGFloat = 8
    /// Frames a second of the strips: the rate the robot was always drawn at.
    static let fps = 30.0
    /// Core Animation would otherwise run the robot at the screen's refresh rate (up to 120 Hz), and the
    /// window server would composite the notch that often.
    static let frameRate = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)

    private var look: RobotLook?
    private var revivingUntil: Date?
    private var paused = false
    private var built: (look: RobotLook, size: CGSize, scale: CGFloat)?
    private var rebuildLater: DispatchWorkItem?

    private let root = CALayer()
    private let stage = CALayer()
    private let head = CALayer()
    private let revive = CALayer()
    private let body = CALayer()
    private let burntBody = CALayer()
    private let eyeShiftLayer = CALayer()
    private let eyes = CALayer()
    private let drop = CALayer()
    private let embers = CALayer()
    private let smoke = CALayer()
    private let particles = CALayer()
    private var strips: [CALayer: Flipbook] = [:]

    init() {
        super.init(frame: .zero)
        // Layers keep Core Animation's y axis, growing upwards; drawRobot's y grows downwards, so every
        // position, pivot and movement below is converted (see `up`).
        layer = root
        wantsLayer = true
        root.addSublayer(stage)
        stage.addSublayer(head)
        head.addSublayer(revive)
        for l in [body, burntBody, eyeShiftLayer, drop, embers, smoke, particles] { revive.addSublayer(l) }
        eyeShiftLayer.addSublayer(eyes)
        for l in [root, stage, head, revive, body, burntBody, eyeShiftLayer, eyes, drop, embers, smoke, particles] {
            l.actions = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(), "contentsRect": NSNull(),
                         "transform": NSNull(), "opacity": NSNull(), "hidden": NSNull(), "sublayerTransform": NSNull()]
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(look: RobotLook, revivingUntil: Date?, paused: Bool) {
        let lookChanged = look != self.look, pausedChanged = paused != self.paused
        self.look = look
        self.paused = paused
        if lookChanged { rebuild() } else if pausedChanged { animate() }
        if let until = revivingUntil, until != self.revivingUntil, until > Date() { animateRevival(until) }
        self.revivingUntil = revivingUntil
    }

    override func layout() {
        super.layout()
        guard let built, bounds.size != built.size, built.size.width > 0, bounds.width > 0 else {
            if built == nil { rebuild() }
            return
        }
        // While the panel's spring is running, scale what is there and redraw sharp once it settles.
        let k = min(bounds.width / built.size.width, bounds.height / built.size.height)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.position = CGPoint(x: bounds.midX, y: bounds.midY)
        stage.transform = CATransform3DMakeScale(k, k, 1)
        CATransaction.commit()
        rebuildLater?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildLater = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rebuild()
    }

    /// A y measured from the top, as drawRobot does, turned into Core Animation's y from the bottom.
    private func up(_ y: CGFloat, in height: CGFloat) -> CGFloat { height - y }

    /// Where the grid sits in the view, as drawRobot places it (y from the top).
    private func grid(_ size: CGSize) -> (origin: CGPoint, scale: CGFloat) {
        let s = min(size.width / 60, size.height / 46)
        return (CGPoint(x: (size.width - 60 * s) / 2, y: (size.height - 46 * s) / 2), s)
    }

    private func rebuild() {
        guard let look, bounds.width > 0, bounds.height > 0 else { return }
        rebuildLater?.cancel()
        let size = bounds.size
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let (o, s) = grid(size)
        let m = Self.margin
        CATransaction.begin(); CATransaction.setDisableActions(true)
        stage.bounds = CGRect(origin: .zero, size: size)
        stage.position = CGPoint(x: size.width / 2, y: size.height / 2)
        stage.transform = CATransform3DIdentity
        root.contentsScale = scale
        // Peeking: the head is cut at the bottom of the grid, the edge of the notch.
        if look.peeking {
            let mask = CALayer()
            mask.backgroundColor = .black
            mask.frame = CGRect(x: o.x, y: up(o.y + 46 * s, in: size.height), width: 60 * s, height: 46 * s)
            stage.mask = mask
        } else {
            stage.mask = nil
        }
        // The head turns around (30, 25) on the grid.
        let pivot = CGPoint(x: o.x + 30 * s, y: up(o.y + 25 * s, in: size.height))
        for l in [head, revive] {
            l.bounds = CGRect(origin: .zero, size: size)
            l.anchorPoint = CGPoint(x: pivot.x / size.width, y: pivot.y / size.height)
            l.position = pivot
            l.transform = CATransform3DIdentity
        }
        eyeShiftLayer.frame = CGRect(origin: .zero, size: size)
        strips = [:]
        for l in [body, burntBody, eyes, drop, embers, smoke, particles] {
            l.frame = tileFrame(CGSize(width: size.width + 2 * m, height: size.height + 2 * m), in: size)
            l.contentsScale = scale
            l.contentsGravity = .resize
            l.contents = nil
            l.isHidden = false
            l.opacity = 1
        }
        let c = look.color, tired = look.tired, peeking = look.peeking
        func strip(_ part: RobotPart, period: Double?, revival: Double? = nil) -> Flipbook {
            Flipbook(part: part, look: look, period: period, size: size, scale: scale, revival: revival)
        }
        show(strip(.body, period: nil), in: body)
        show(strip(.eyes, period: eyesPeriod(c, tired: tired, peeking: peeking)), in: eyes)
        let sweats = tired && (c == .blue || c == .backgroundBlue)
        drop.isHidden = !sweats
        if sweats { show(strip(.drop, period: 1.6), in: drop) }
        embers.isHidden = c != .burnt
        smoke.isHidden = c != .burnt
        if c == .burnt {
            show(strip(.embers, period: 1.4), in: embers)
            show(strip(.smoke, period: 2.6), in: smoke)
        }
        burntBody.opacity = 0
        particles.opacity = 0
        CATransaction.commit()
        built = (look, size, scale)
        animate()
        if let until = revivingUntil, until > Date() { animateRevival(until) }
    }

    /// A frame of a strip is drawn from (-margin, -margin) of the view, measured from the top.
    private func tileFrame(_ tile: CGSize, in size: CGSize) -> CGRect {
        let m = Self.margin
        return CGRect(x: -m, y: up(-m, in: size.height) - tile.height, width: tile.width, height: tile.height)
    }

    private func show(_ f: Flipbook, in layer: CALayer) {
        layer.frame = tileFrame(f.tileSize, in: bounds.size)
        layer.contents = f.image
        layer.contentsRect = f.rects.first ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        strips[layer] = f
    }

    /// The loop of each part's eyes, as drawRobot draws them (nil: they don't change).
    private func eyesPeriod(_ c: RobotColor, tired: Bool, peeking: Bool) -> Double? {
        switch c {
        case .red: return 2.1                                // flames 0.42 s and cores 0.3 s
        case .blue where tired, .backgroundBlue where tired: return 2.6   // drooping eyes
        case .backgroundBlue: return peeking ? 5 : 4        // blinking
        case .yellow: return 1.6                             // eyes and "!" taking turns
        case .dimGreen: return 5                             // blinking
        case .gray: return 2.4                               // Z z lighting up in turn
        default: return nil
        }
    }

    /// Starts the loops, in step with the clock drawRobot uses.
    private func animate() {
        for l in [head, eyeShiftLayer, eyes, drop, embers, smoke] { l.removeAnimation(forKey: "loop") }
        guard !paused, let look, let built else { return }
        let refNow = Date().timeIntervalSinceReferenceDate
        let mediaNow = root.convertTime(CACurrentMediaTime(), from: nil)
        let (_, s) = grid(built.size)
        func loop(_ anim: CAAnimation, _ period: Double, on layer: CALayer) {
            anim.preferredFrameRateRange = Self.frameRate
            anim.duration = period
            anim.repeatCount = .infinity
            anim.beginTime = mediaNow
            anim.timeOffset = refNow.truncatingRemainder(dividingBy: period)
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: "loop")
        }
        // Head movement and eye scan: keyframes sampled from the same functions, 60 a second.
        if let period = headPeriod(look.color, peeking: look.peeking) {
            loop(keyframes("transform", period) { t in
                let (sway, dy, tilt) = headMotion(look.color, peeking: look.peeking, t)
                // drawRobot's y grows downwards and its positive tilt turns clockwise: both flip here.
                return NSValue(caTransform3D: CATransform3DConcat(CATransform3DMakeRotation(-tilt * .pi / 180, 0, 0, 1),
                                                                  CATransform3DMakeTranslation(sway * s, -dy * s, 0)))
            }, period, on: head)
        }
        if let period = eyeShiftPeriod(look.color) {
            loop(keyframes("transform.translation.x", period) { t in
                NSNumber(value: Double(eyeShift(look.color, peeking: look.peeking, t) * s))
            }, period, on: eyeShiftLayer)
        }
        // Strips of frames: each frame held for its 1/30 s, identical frames merged.
        for (layer, f) in strips {
            guard let period = f.period, f.runs.count > 1 else { continue }
            let anim = CAKeyframeAnimation(keyPath: "contentsRect")
            anim.calculationMode = .discrete
            anim.values = f.runs.map { NSValue(rect: f.rects[$0.frame]) }
            anim.keyTimes = (f.runs.map { $0.start } + [1]).map { NSNumber(value: $0) }
            loop(anim, period, on: layer)
        }
    }

    private func headPeriod(_ c: RobotColor, peeking: Bool) -> Double? {
        switch c {
        case .red: return 0.32
        case .burnt: return 3
        case .yellow: return 0.9
        case .green: return 1.5
        case .gray: return 3.2
        case .backgroundBlue where peeking: return 5
        default: return nil
        }
    }

    private func eyeShiftPeriod(_ c: RobotColor) -> Double? {
        switch c {
        case .blue: return 1.3
        case .backgroundBlue: return 4
        default: return nil
        }
    }

    /// Keyframes of one period, 60 a second, the last equal to the first so the loop is seamless.
    private func keyframes(_ keyPath: String, _ period: Double, _ value: (Double) -> Any) -> CAKeyframeAnimation {
        let n = max(2, Int((period * 60).rounded()))
        let anim = CAKeyframeAnimation(keyPath: keyPath)
        anim.values = (0...n).map { value(period * Double($0) / Double(n)) }
        anim.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        anim.calculationMode = .linear
        return anim
    }

    /// Reviving (0.8 s): the soot shake, the burnt shell fading into the new color and the soot flying off.
    private func animateRevival(_ until: Date) {
        guard !paused, let look, let built else { return }
        let start = until.timeIntervalSinceReferenceDate - 0.8
        let refNow = Date().timeIntervalSinceReferenceDate
        let begin = root.convertTime(CACurrentMediaTime(), from: nil) + (start - refNow)
        func once(_ anim: CAAnimation, on layer: CALayer, key: String) {
            anim.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)   // the 10 Hz shake
            anim.duration = 0.8
            anim.beginTime = begin
            anim.isRemovedOnCompletion = true
            layer.add(anim, forKey: key)
        }
        let shake = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let n = 96   // 120 a second
        shake.values = (0...n).map { j -> NSNumber in
            let p = Double(j) / Double(n)
            return NSNumber(value: -revivalShake(p, start + 0.8 * p) * .pi / 180)
        }
        shake.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        once(shake, on: revive, key: "revive")
        // The burnt shell on top fades out linearly: over the new shell it blends exactly like drawRobot's mix.
        let burnt = Flipbook(part: .body, look: look, period: nil, size: built.size, scale: built.scale, revival: 0)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        burntBody.frame = tileFrame(burnt.tileSize, in: built.size)
        burntBody.contents = burnt.image
        burntBody.contentsRect = burnt.rects.first ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        once(fade, on: burntBody, key: "revive")
        let soot = Flipbook(part: .particles, look: look, period: 0.8, size: built.size, scale: built.scale, revival: nil)
        particles.frame = tileFrame(soot.tileSize, in: built.size)
        particles.contents = soot.image
        CATransaction.commit()
        let frames = CAKeyframeAnimation(keyPath: "contentsRect")
        frames.calculationMode = .discrete
        frames.values = soot.runs.map { NSValue(rect: soot.rects[$0.frame]) }
        frames.keyTimes = (soot.runs.map { $0.start } + [1]).map { NSNumber(value: $0) }
        let visible = CAKeyframeAnimation(keyPath: "opacity")
        visible.values = [1, 1]
        let group = CAAnimationGroup()
        group.animations = [frames, visible]
        once(group, on: particles, key: "revive")
    }
}

/// A part of the robot drawn by drawRobot at 30 frames a second over its period, identical frames kept once,
/// side by side in one image.
private struct Flipbook {
    let image: CGImage?
    let rects: [CGRect]                       // contentsRect of each kept frame
    let runs: [(start: Double, frame: Int)]   // where each run of identical frames starts, in the period
    let period: Double?
    let tileSize: CGSize                      // one frame, in points, a whole number of pixels wide and high

    @MainActor
    init(part: RobotPart, look: RobotLook, period: Double?, size: CGSize, scale: CGFloat, revival: Double?) {
        self.period = period
        let m = RobotLayerView.margin
        // Whole pixels per frame, or the frames would drift when they are cut out of the strip.
        let tilePx = (w: Int(((size.width + 2 * m) * scale).rounded(.up)), h: Int(((size.height + 2 * m) * scale).rounded(.up)))
        let tile = CGSize(width: CGFloat(tilePx.w) / scale, height: CGFloat(tilePx.h) / scale)
        tileSize = tile
        let count = period.map { max(1, Int(($0 * RobotLayerView.fps).rounded())) } ?? 1
        let times: [Double] = (0..<count).map { i in (period ?? 0) * Double(i) / Double(count) }
        // Particles play once over the revival: their frame number is the revival's progress.
        let progress: [Double?] = part == .particles ? (0..<count).map { Double($0) / Double(count) } : times.map { _ in revival }
        let sheet = Canvas { g, _ in
            for i in 0..<count {
                var gg = g
                gg.translateBy(x: CGFloat(i) * tile.width + m, y: m)
                drawRobot(&gg, size, look.color, look.tired, times[i], peeking: look.peeking,
                          bandaged: look.bandaged, revival: progress[i], part: part)
            }
        }
        .frame(width: tile.width * CGFloat(count), height: tile.height)
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = scale
        guard let full = renderer.cgImage, full.width >= tilePx.w * count, full.height >= tilePx.h else {
            image = nil; rects = []; runs = []; return
        }
        // Keeps each distinct frame once.
        let tileW = tilePx.w, tileH = tilePx.h
        let pixels = Flipbook.bytes(full)
        var kept: [Int] = []          // frame index in `full` of each kept frame
        var runs: [(start: Double, frame: Int)] = []
        for i in 0..<count {
            let same = kept.firstIndex { Flipbook.equal(pixels, full.width, tileW, tileH, $0, i) }
            let k = same ?? { kept.append(i); return kept.count - 1 }()
            if runs.last?.frame != k { runs.append((Double(i) / Double(count), k)) }
        }
        let ctx = CGContext(data: nil, width: tileW * kept.count, height: tileH, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (k, i) in kept.enumerated() {
            if let piece = full.cropping(to: CGRect(x: i * tileW, y: 0, width: tileW, height: tileH)) {
                ctx.draw(piece, in: CGRect(x: k * tileW, y: 0, width: tileW, height: tileH))
            }
        }
        image = ctx.makeImage()
        rects = (0..<kept.count).map { CGRect(x: Double($0) / Double(kept.count), y: 0, width: 1 / Double(kept.count), height: 1) }
        self.runs = runs
    }

    private static func bytes(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return data
    }

    private static func equal(_ px: [UInt8], _ width: Int, _ tileW: Int, _ tileH: Int, _ a: Int, _ b: Int) -> Bool {
        // Rows of the strip are `width` pixels long; frame k starts at pixel k * tileW of each row.
        let row = width * 4, len = tileW * 4
        return px.withUnsafeBufferPointer { p in
            (0..<tileH).allSatisfy { y in memcmp(p.baseAddress! + y * row + a * len, p.baseAddress! + y * row + b * len, len) == 0 }
        }
    }
}

/// The panic edge around the notch, pulsing on Core Animation.
struct PanicBorder: NSViewRepresentable {
    let radius: CGFloat
    var paused = false

    func makeNSView(context: Context) -> PanicBorderView { PanicBorderView() }
    func updateNSView(_ view: PanicBorderView, context: Context) { view.update(radius: radius, paused: paused) }
}

final class PanicBorderView: NSView {
    private let shape = CAShapeLayer()
    private var radius: CGFloat = 0
    private var paused = false

    init() {
        super.init(frame: .zero)
        let root = CALayer()
        layer = root
        wantsLayer = true
        shape.fillColor = nil
        shape.strokeColor = NSColor(srgbRed: 0xE2 / 255, green: 0x4B / 255, blue: 0x4A / 255, alpha: 1).cgColor
        shape.lineWidth = 1.75
        shape.actions = ["path": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        root.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(radius: CGFloat, paused: Bool) {
        let changed = paused != self.paused
        self.radius = radius
        self.paused = paused
        needsLayout = true
        if changed || shape.animation(forKey: "pulse") == nil { pulse() }
    }

    override func layout() {
        super.layout()
        shape.frame = bounds
        // Like strokeBorder: the line sits inside the shape, so the outline is inset by half its width.
        let w = shape.lineWidth / 2, r = max(0, radius - w)
        let rect = bounds.insetBy(dx: w, dy: w)
        let path = CGMutablePath()
        // Core Animation's y grows upwards: the top edge is maxY and the rounded corners are at minY.
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.closeSubpath()
        shape.path = path
    }

    /// Opacity between 25% and 100% every 1.2 s, in step with the clock.
    private func pulse() {
        shape.removeAnimation(forKey: "pulse")
        guard !paused else { return }
        let n = 72
        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = (0...n).map { NSNumber(value: 0.625 + 0.375 * sin(2 * .pi * Double($0) / Double(n))) }
        anim.keyTimes = (0...n).map { NSNumber(value: Double($0) / Double(n)) }
        anim.duration = 1.2
        anim.repeatCount = .infinity
        anim.preferredFrameRateRange = RobotLayerView.frameRate
        anim.beginTime = shape.convertTime(CACurrentMediaTime(), from: nil)
        anim.timeOffset = Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2)
        anim.isRemovedOnCompletion = false
        shape.add(anim, forKey: "pulse")
    }
}
