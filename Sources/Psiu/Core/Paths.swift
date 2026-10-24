// Psiu: a tiny robot in the Mac's notch that shows the state of your Claude Code sessions.
// One binary with several modes:
//   Psiu               opens the robot in the notch (menu bar app, no Dock icon)
//   Psiu hook          receives Claude Code events (called by the hooks)
//   Psiu statusline    receives context and plan limits (called by the status line)
//   Psiu install / uninstall   adds or removes Psiu in ~/.claude/settings.json
//   Psiu setup         connects Psiu without a window: migrates Farol, writes hooks and status line, opens at login
//   Psiu icon <png>    draws the app icon (used by build-dmg.sh)
//   Psiu dmg-background <dir>   draws the installer background (used by build-dmg.sh)
// The Portuguese mode names of earlier versions (configurar, icone, fundo-dmg) still work.
// No internet access, never reads tokens or passwords. Everything stays in ~/.psiu.

import Foundation

// MARK: - Paths and utilities

// Names on disk (placar.json, statusline-anterior.txt and keys such as "mudo" or "resumo") stay in Portuguese,
// as in earlier versions and in Farol, so existing installs keep their scoreboard, preferences and sessions.
let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? fm.homeDirectoryForCurrentUser
let baseDir = home.appendingPathComponent(".psiu")
let sessionsDir = baseDir.appendingPathComponent("sessions")
let limitsFile = baseDir.appendingPathComponent("limits.json")
let prefsFile = baseDir.appendingPathComponent("prefs.json")
let prevStatusFile = baseDir.appendingPathComponent("statusline-anterior.txt")
/// The executable itself: /Applications/Psiu.app/Contents/MacOS/Psiu once installed.
let binPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
/// Version of the installed app, or nil when running outside Psiu.app.
let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

/// Portuguese when the Mac's first language is Brazilian Portuguese; English otherwise.
let isPortuguese: Bool = {
    let l = Locale.preferredLanguages.first ?? ""
    return l == "pt" || l.hasPrefix("pt-BR")
}()

/// Picks the text in the system language.
func tr(_ pt: String, _ en: String) -> String { isPortuguese ? pt : en }

/// Recognizes Psiu and Farol (the previous version) commands, to swap one for the other without duplicates.
func isPsiuCommand(_ cmd: String) -> Bool {
    cmd.contains("/Psiu.app/Contents/MacOS/Psiu") || cmd.contains("/.farol/bin/Farol")
}

func ensureDirs() {
    try? fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
}

func readJSON(_ url: URL) -> [String: Any]? {
    guard let d = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

func writeJSON(_ obj: [String: Any], to url: URL, pretty: Bool = false) {
    let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .withoutEscapingSlashes] : []
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: opts) {
        try? d.write(to: url, options: .atomic)
    }
}

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

func safeID(_ s: String) -> String {
    String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
}
