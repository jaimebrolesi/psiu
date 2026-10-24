import PsiuCore
import SwiftUI

// MARK: - Visuals

func swiftUIColor(_ c: RobotColor) -> Color {
    switch c {
    case .red: return Palette.panic
    case .burnt: return Palette.burnt
    case .yellow: return Color(red: 1.0, green: 0.80, blue: 0.10)
    case .blue, .backgroundBlue: return Color(red: 0.25, green: 0.60, blue: 1.0)
    case .green: return Color(red: 0.20, green: 0.85, blue: 0.40)
    case .dimGreen: return Color(red: 0.20, green: 0.85, blue: 0.40).opacity(0.35)
    case .gray: return Color.gray.opacity(0.35)
    }
}

func stateColor(_ e: SessionState) -> Color {
    switch e {
    case .awaiting: return swiftUIColor(.yellow)
    case .running, .background: return swiftUIColor(.blue)
    case .done: return swiftUIColor(.green)
    case .idle: return swiftUIColor(.dimGreen)
    }
}

func usageColor(_ pct: Double) -> Color {
    pct >= 90 ? .red : pct >= 75 ? .orange : Color(red: 0.20, green: 0.75, blue: 0.40)
}
