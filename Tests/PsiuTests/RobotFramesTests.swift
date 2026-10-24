import AppKit
import SwiftUI
import Testing
@testable import Psiu

/// The robot drawn now against frames saved from Psiu 1.6.2, so a refactor can't change how it looks.
/// Each file name holds the look: color_tired_peeking_bandaged_revival_time.png.
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
        let f = name.split(separator: "_").map(String.init)
        try #require(f.count == 6, "unexpected file name \(name)")
        let color = try #require(Self.colors[f[0]])
        let tired = f[1] == "true", peeking = f[2] == "true", bandaged = f[3] == "true"
        let revival = Double(f[4]), t = try #require(Double(f[5]))
        let view = Canvas { g, _ in
            g.translateBy(x: 10, y: 10)
            drawRobot(&g, CGSize(width: 60, height: 46), color, tired, t, peeking: peeking, bandaged: bandaged, revival: revival)
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
        #expect(Self.goldenFiles.count == 60)
    }

    @Test(arguments: goldenFiles)
    func matchesTheSavedFrame(_ file: URL) throws {
        let name = file.deletingPathExtension().lastPathComponent
        let saved = try #require(NSBitmapImageRep(data: Data(contentsOf: file))?.cgImage)
        let drawn = try render(name)
        try #require(drawn.width == saved.width && drawn.height == saved.height)
        let a = pixels(saved), b = pixels(drawn)
        // Anti-aliasing may differ by a hair between macOS versions; a changed shape or color moves far more.
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
