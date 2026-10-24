import Foundation
@testable import PsiuCore

/// A home of its own in the temporary folder, removed when the test ends.
final class TemporaryHome {
    let paths: PsiuPaths

    init() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("psiu-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        paths = PsiuPaths(home: url)
        paths.ensureDirectories()
    }

    deinit { try? FileManager.default.removeItem(at: paths.home) }
}

/// The executable path the installer writes into settings.json.
let psiuExecutable = "/Applications/Psiu.app/Contents/MacOS/Psiu"

/// Stands in for the terminal lookup, which runs `ps`.
func noTerminal() -> TerminalInfo { TerminalInfo(bundle: "com.apple.Terminal", termprog: "Apple_Terminal", tty: "/dev/ttys001") }

func session(_ id: String, _ state: SessionState, since: Double, updated: Double? = nil, ctx: Double? = nil,
             compactions: Int = 0) -> Session {
    Session(id: id, project: id, state: state, since: since, updated: updated ?? since, ctx: ctx, compactions: compactions)
}

func json(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}
