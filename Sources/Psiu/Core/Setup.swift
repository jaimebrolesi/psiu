import Foundation
import ServiceManagement

// MARK: - First run, login and migration from Farol

/// Is Psiu already connected to Claude Code through this executable?
func isPsiuConnected() -> Bool {
    guard let data = try? Data(contentsOf: settingsURL),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let cmd = (obj["statusLine"] as? [String: Any])?["command"] as? String else { return false }
    return cmd.contains(binPath)
}

/// Does settings.json lack any of Psiu's hook events for this executable (an install from an older version)?
func isMissingHooks() -> Bool {
    let hooks = readJSON(settingsURL)?["hooks"] as? [String: Any] ?? [:]
    return hookEvents.contains { event, _ in
        let groups = hooks[event] as? [[String: Any]] ?? []
        return !groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains(binPath) }
        }
    }
}

var hasFarol: Bool {
    fm.fileExists(atPath: home.appendingPathComponent(".farol").path)
        || fm.fileExists(atPath: home.appendingPathComponent("Library/LaunchAgents/com.farol.app.plist").path)
}

/// Turns off Farol (the previous version) and brings its scoreboard, preferences and saved status line over to Psiu.
func migrateFromFarol() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootout", "gui/\(getuid())/com.farol.app"]
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    try? fm.removeItem(at: home.appendingPathComponent("Library/LaunchAgents/com.farol.app.plist"))
    let farolDir = home.appendingPathComponent(".farol")
    guard fm.fileExists(atPath: farolDir.path) else { return }
    ensureDirs()
    for name in ["placar.json", "prefs.json", "statusline-anterior.txt"] {
        let src = farolDir.appendingPathComponent(name), dst = baseDir.appendingPathComponent(name)
        if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
    }
    try? fm.removeItem(at: farolDir)
    // Claude Code sessions opened before the switch still call ~/.farol/bin/Farol.
    // That path becomes a link to Psiu, so they keep working until they are restarted.
    try? fm.createDirectory(at: farolDir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: farolDir.appendingPathComponent("bin/Farol").path, withDestinationPath: binPath)
}

/// Connects Psiu without a window: migrates Farol, writes hooks and status line, and registers open at login.
func setupWithoutWindow() {
    migrateFromFarol()
    runInstall()
    do {
        try SMAppService.mainApp.register()
        print(SMAppService.mainApp.status == .requiresApproval
              ? tr("Abertura no login registrada; falta autorizar em Ajustes do Sistema → Geral → Itens de Início.", "Open at login registered; approve it in System Settings → General → Login Items.")
              : tr("Abertura no login registrada.", "Open at login registered."))
    } catch {
        print(tr("Não consegui registrar a abertura no login: \(error.localizedDescription)", "Couldn't register open at login: \(error.localizedDescription)"))
    }
}
