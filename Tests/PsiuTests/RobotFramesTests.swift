import AppKit
import SwiftUI
import Testing
@testable import Psiu

/// The robot drawn now against frames saved from Psiu 1.6.2 (the revival's smoke and the relief from 1.6.6), so a
/// refactor can't change how it looks. Each file name holds the look: color_tired_peeking_bandaged_revival_time.png,
/// plus _relief-from-progress for the relief and _headset with the headset on (both from 1.8.1, with the blue drop).
@Suite("Robot frames")
@MainActor
struct RobotFramesTests {
    static let colors: [String: RobotColor] = [
        "red": .red, "burnt": .burnt, "yellow": .yellow, "blue": .blue, "backgroundBlue": .backgroundBlue,
        "green": .green, "dimGreen": .dimGreen, "gray": .gray,
    ]

    nonisolated static var goldenFiles: [URL] {
        let dir = Bundle.module.resourceURL!.appendingPathComponent("Golden")
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Draws one look the way the golden frames were made: the 60 x 46 grid in an 80 x 66 canvas, at 2x.
    func render(_ name: String) throws -> CGImage {
        var f = name.split(separator: "_").map(String.init)
        let headset = f.last == "headset"
        if headset { f.removeLast() }
        try #require(f.count == 6 || f.count == 7, "unexpected file name \(name)")
        let color = try #require(Self.colors[f[0]])
        let tired = f[1] == "true", peeking = f[2] == "true", bandaged = f[3] == "true"
        let revival = Double(f[4]), t = try #require(Double(f[5]))
        var relief: RobotRelief?
        if f.count == 7 {
            let r = f[6].split(separator: "-").map(String.init)
            try #require(r.count == 3 && r[0] == "relief", "unexpected relief in \(name)")
            relief = RobotRelief(from: try #require(Self.colors[r[1]]), progress: try #require(Double(r[2])))
        }
        let view = Canvas { g, _ in
            g.translateBy(x: 10, y: 10)
            drawRobot(&g, CGSize(width: 60, height: 46), color, tired, t, peeking: peeking, bandaged: bandaged, headset: headset,
                      revival: revival, relief: relief)
        }
        .frame(width: 80, height: 66)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    /// RGBA bytes of an image, in a known layout so two images can be compared byte by byte.
    func pixels(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    @Test func thereAreGoldenFrames() {
        #expect(Self.goldenFiles.count == 73)
    }

    /// Saves the frames again into $PSIU_GOLDEN (only when it is set): after a change Jaime approved.
    @Test func saveFrames() throws {
        guard let dir = ProcessInfo.processInfo.environment["PSIU_GOLDEN"] else { return }
        var names = Self.goldenFiles.map { $0.deletingPathExtension().lastPathComponent }
        for from in ["yellow", "red"] {
            for p in ["0.1", "0.4", "0.6", "0.9"] { names.append("blue_false_false_false_nil_0.37_relief-\(from)-\(p)") }
        }
        names += ["blue_false_false_false_nil_0.37", "blue_true_false_false_nil_1.1", "backgroundBlue_false_false_false_nil_0.37",
                  "backgroundBlue_false_true_false_nil_2.9", "dimGreen_false_false_false_nil_0.37"].map { $0 + "_headset" }
        for name in Set(names) {
            let rep = NSBitmapImageRep(cgImage: try render(name))
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
        }
    }

    /// Happy, waiting, in panic, burnt or asleep, Psiu takes the headset off.
    @Test(arguments: ["green", "yellow", "red", "burnt", "gray"])
    func noHeadsetOutsideWorkAndIdle(_ color: String) throws {
        let name = "\(color)_false_false_false_nil_0.37"
        expectSame(try render(name), try render(name + "_headset"), name)
    }

    @Test(arguments: goldenFiles)
    func matchesTheSavedFrame(_ file: URL) throws {
        let name = file.deletingPathExtension().lastPathComponent
        let saved = try #require(NSBitmapImageRep(data: Data(contentsOf: file))?.cgImage)
        let drawn = try render(name)
        try #require(drawn.width == saved.width && drawn.height == saved.height)
        expectSame(saved, drawn, name)
    }

    /// Anti-aliasing may differ by a hair between renders and macOS versions; a changed shape or color moves far more.
    func expectSame(_ x: CGImage, _ y: CGImage, _ name: String) {
        let a = pixels(x), b = pixels(y)
        var off = 0, total = 0
        for i in a.indices {
            let d = abs(Int(a[i]) - Int(b[i]))
            total += d
            if d > 8 { off += 1 }
        }
        #expect(Double(off) / Double(a.count) < 0.002, "\(name): \(off) channels differ")
        #expect(Double(total) / Double(a.count) < 0.5, "\(name): mean difference \(Double(total) / Double(a.count))")
    }
}
