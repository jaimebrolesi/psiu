import Foundation

/// Where Psiu keeps its files. Names on disk (placar.json, statusline-anterior.txt and keys such as "mudo" or
/// "resumo") stay in Portuguese, as in earlier versions and in Farol, so existing installs keep their data.
public struct PsiuPaths: Sendable, Equatable {
    public let home: URL

    public init(home: URL) { self.home = home }

    /// The user's home, or $HOME when it is set (tests and test.sh use a temporary one).
    public static let current = PsiuPaths(home: ProcessInfo.processInfo.environment["HOME"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser)

    public var base: URL { home.appendingPathComponent(".psiu") }
    public var sessions: URL { base.appendingPathComponent("sessions") }
    public var limits: URL { base.appendingPathComponent("limits.json") }
    public var prefs: URL { base.appendingPathComponent("prefs.json") }
    public var scoreboard: URL { base.appendingPathComponent("placar.json") }
    public var previousStatusLine: URL { base.appendingPathComponent("statusline-anterior.txt") }
    public var lock: URL { base.appendingPathComponent("psiu.lock") }
    /// Held by each hook while it reads and writes a session's file.
    public var hooksLock: URL { base.appendingPathComponent("hooks.lock") }
    /// While this file exists, the panel stays open (record-demo.sh uses it).
    public var demoPanel: URL { base.appendingPathComponent("demo-panel") }
    public var settings: URL { home.appendingPathComponent(".claude/settings.json") }
    public var farol: URL { home.appendingPathComponent(".farol") }
    public var farolAgent: URL { home.appendingPathComponent("Library/LaunchAgents/com.farol.app.plist") }

    public func session(_ id: String) -> URL { sessions.appendingPathComponent("\(id).json") }
    public func metrics(_ id: String) -> URL { sessions.appendingPathComponent("\(id).metrics.json") }

    public func ensureDirectories() {
        try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    }
}

/// The executable itself: /Applications/Psiu.app/Contents/MacOS/Psiu once installed.
public let executablePath = Bundle.main.executablePath ?? CommandLine.arguments[0]

/// Recognizes Psiu and Farol (the previous version) commands, to swap one for the other without duplicates.
public func isPsiuCommand(_ cmd: String) -> Bool {
    cmd.contains("/Psiu.app/Contents/MacOS/Psiu") || cmd.contains("/.farol/bin/Farol")
}

/// Session IDs become file names: only letters, digits, "-" and "_".
func safeID(_ s: String) -> String {
    String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" })
}
