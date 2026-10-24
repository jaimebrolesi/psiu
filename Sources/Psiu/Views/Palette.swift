import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// The app's colors outside the robot drawing, in one place.
enum Palette {
    static let panic = Color(hex: 0xE24B4A)          // red Psiu, a session waiting 10 min or more
    static let burnt = Color(hex: 0x554A43)          // burnt Psiu, 30 min or more
    static let finishedDot = Color(hex: 0x97C459)    // green dot: a session finished while Psiu shows another color
    static let tired = Color(hex: 0xAFA9EC)          // purple: context above 80%
    static let tiredOutline = Color(hex: 0xAFA9EC, alpha: 0.55)
    static let tiredText = Color(hex: 0xCECBF6)      // compaction tag and tip
    static let warning = Color(hex: 0xFAC775)        // forecast and time waiting for you
    static let forecastOverflow = Color(hex: 0xEF9F27, alpha: 0.4)
    static let working = Color(hex: 0x378ADD)        // scoreboard bar: agent working
    static let waiting = Color(hex: 0xEF9F27)        // scoreboard bar: waiting for you

    // Installer art (BuildArt)
    static let iconBackground = Color(hex: 0x1C1C1E)
    static let installerBackground = Color(hex: 0x17181B)
    static let installerGlow = Color(hex: 0x24364F, alpha: 0.6)
    static let arrow = Color(hex: 0x97C459)
    static let labelPlate = Color(hex: 0xE4E7EC)
}
