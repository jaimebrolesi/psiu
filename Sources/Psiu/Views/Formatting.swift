import Foundation

func formatDuration(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    if m >= 60 { return "\(m / 60)h \(m % 60)min" }
    if m >= 1 { return "\(m) min" }
    return "\(Int(seconds)) s"
}

/// One formatter per format, made once: creating a DateFormatter on every redraw of the panel is costly.
@MainActor private var shortTimeFormatters: [String: DateFormatter] = [:]

@MainActor func shortTime(_ epoch: Double, _ format: String = "HH'h'mm") -> String {
    let f = shortTimeFormatters[format] ?? {
        let f = DateFormatter()
        if isPortuguese {
            f.locale = Locale(identifier: "pt_BR")
            f.dateFormat = format
        } else {
            // English with the region's conventions (12 or 24 hours).
            f.locale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
            f.setLocalizedDateFormatFromTemplate(format.contains("EEE") ? "EEEjmm" : "jmm")
        }
        shortTimeFormatters[format] = f
        return f
    }()
    return f.string(from: Date(timeIntervalSince1970: epoch))
}
