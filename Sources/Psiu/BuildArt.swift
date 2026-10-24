import AppKit
import SwiftUI

/// Draws the app icon (1024 px) with the robot's head.
@MainActor
func renderIcon(_ outputPath: String) {
    let view = ZStack {
        RoundedRectangle(cornerRadius: 185, style: .continuous)
            .fill(Color(hex: 0x1C1C1E))
            .frame(width: 824, height: 824)
        Canvas { g, size in drawRobot(&g, size, .green, false, 0) }
            .frame(width: 620, height: 475)
    }
    .frame(width: 1024, height: 1024)
    let r = ImageRenderer(content: view)
    r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print(tr("Não consegui desenhar o ícone.", "Couldn't draw the icon.")); exit(1)
    }
    try? png.write(to: URL(fileURLWithPath: outputPath))
}

/// Installer (.dmg) window background: 640 x 400, with an arrow from the app to Applications. Bilingual, since it is a single image.
struct DMGBackground: View {
    // Icon centers in the window, the same ones build-dmg.sh uses in Finder.
    static let app = CGPoint(x: 170, y: 190)
    static let folder = CGPoint(x: 470, y: 190)

    var body: some View {
        ZStack {
            Color(hex: 0x17181B)
            RadialGradient(colors: [Color(hex: 0x24364F, alpha: 0.6), .clear],
                           center: UnitPoint(x: 0.5, y: 0.48), startRadius: 10, endRadius: 380)
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Canvas { g, size in drawRobot(&g, size, .green, false, 0) }
                        .frame(width: 34, height: 26)
                    Text("Psiu").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                }
                Text("Avisa quando o Claude Code precisa de você\nTells you when Claude Code needs you")
                    .font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.center).lineSpacing(2)
            }
            .position(x: 320, y: 64)
            // Over a background picture Finder always draws icon names in black, even in dark mode:
            // a light plate behind each name keeps them readable.
            labelPlate(58).position(x: Self.app.x, y: 265)
            labelPlate(98).position(x: Self.folder.x, y: 265)
            curve.stroke(Color(hex: 0x97C459),
                         style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0.1, 9]))
            arrowhead.stroke(Color(hex: 0x97C459),
                         style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Text("Arraste o Psiu para Aplicativos\nDrag Psiu to Applications")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center).lineSpacing(3)
                .position(x: 320, y: 344)
        }
        .frame(width: 640, height: 400)
    }

    func labelPlate(_ plateWidth: CGFloat) -> some View {
        Capsule().fill(Color(hex: 0xE4E7EC)).frame(width: plateWidth, height: 22)
    }

    private let startPoint = CGPoint(x: 252, y: 192)
    private let endPoint = CGPoint(x: 388, y: 192)
    private let controlPoint = CGPoint(x: 320, y: 150)

    var curve: Path {
        var p = Path()
        p.move(to: startPoint)
        p.addQuadCurve(to: endPoint, control: controlPoint)
        return p
    }

    var arrowhead: Path {
        let angle = atan2(endPoint.y - controlPoint.y, endPoint.x - controlPoint.x)
        var p = Path()
        for spread in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
            p.move(to: endPoint)
            p.addLine(to: CGPoint(x: endPoint.x + 13 * cos(angle + spread), y: endPoint.y + 13 * sin(angle + spread)))
        }
        return p
    }
}

/// Saves the .dmg background at 1x and 2x (build-dmg.sh merges both into a .tiff for Retina screens).
@MainActor
func renderDMGBackground(_ folder: String) {
    for (pixelScale, name) in [(CGFloat(1), "background.png"), (CGFloat(2), "background@2x.png")] {
        let r = ImageRenderer(content: DMGBackground())
        r.scale = pixelScale
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print(tr("Não consegui desenhar o fundo do instalador.", "Couldn't draw the installer background.")); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
    }
}
