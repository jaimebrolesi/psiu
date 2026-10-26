import AppKit
import SwiftUI
import Testing
@testable import Psiu

/// The strips of eye frames the robot plays, at the sizes PillView shows it, closed and open, on a 2x screen.
/// A strip too wide for the GPU comes out blank, and the robot loses its eyes (the idle green, open, in 1.7.0).
@Suite("Robot strips")
@MainActor
struct FlipbookTests {
    static let closed = CGSize(width: 26, height: 20)
    static let open = CGSize(width: 42, height: 32)

    @Test(arguments: [RobotColor.red, .burnt, .yellow, .blue, .backgroundBlue, .green, .dimGreen, .gray])
    func everyFrameShowsTheEyes(_ color: RobotColor) throws {
        for size in [Self.closed, Self.open] {
            for tired in [false, true] {
                // Only the closed background blue peeks.
                for peeking in size == Self.closed && color == .backgroundBlue ? [false, true] : [false] {
                    let look = RobotLook(color: color, tired: tired, peeking: peeking, bandaged: false)
                    let period = RobotLayerView.eyesPeriod(color, tired: tired, peeking: peeking)
                    let strip = Flipbook(part: .eyes, look: look, period: period, size: size, scale: 2, revival: nil)
                    let image = try #require(strip.image, "\(look) at \(size)")
                    #expect(image.width <= 16384, "\(look) at \(size): \(image.width) pixels wide")
                    let frames = strip.rects.count, tileW = image.width / frames
                    let px = pixels(image)
                    for k in 0..<frames {
                        let drawn = (0..<image.height).contains { y in
                            (k * tileW..<(k + 1) * tileW).contains { x in px[(y * image.width + x) * 4 + 3] > 0 }
                        }
                        #expect(drawn, "\(look) at \(size): frame \(k) of \(frames) is blank")
                    }
                }
            }
        }
    }

    /// RGBA bytes of an image, in a known layout.
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
}
