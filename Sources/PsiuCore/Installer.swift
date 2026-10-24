import Foundation

// MARK: - Install and uninstall in Claude Code's settings.json

func loadSettings(_ paths: PsiuPaths) -> (dict: [String: Any], rawData: Data?) {
    guard let data = try? Data(contentsOf: paths.settings) else { return ([:], nil) }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        print(tr("O ~/.claude/settings.json não é um JSON válido. Nada foi alterado.", "~/.claude/settings.json is not valid JSON. Nothing was changed."))
        exit(1)
    }
    return (obj, data)
}

/// Keeps only the oldest backup: the settings.json from before Psiu (or Farol). The others are deleted.
func backup(_ data: Data?, _ paths: PsiuPaths) {
    guard let data else { return }
    let fm = FileManager.default
    let dir = paths.settings.deletingLastPathComponent()
    let backupPrefix = "settings.json.psiu-backup-"
    let timestamp: (String) -> Int = { Int($0.split(separator: "-").last ?? "") ?? 0 }
    let backups = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0.hasPrefix(backupPrefix) || $0.hasPrefix("settings.json.farol-backup-") }
        .sorted { timestamp($0) < timestamp($1) }
    if let original = backups.first {
        for name in backups.dropFirst() { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        if backups.count > 1 { print(tr("Backups intermediários apagados: \(backups.count - 1).", "Intermediate backups deleted: \(backups.count - 1).")) }
        print(tr("Backup original preservado: \(dir.appendingPathComponent(original).path)", "Original backup kept: \(dir.appendingPathComponent(original).path)"))
        return
    }
    let url = dir.appendingPathComponent("\(backupPrefix)\(Int(Date().timeIntervalSince1970))")
    try? data.write(to: url)
    print(tr("Backup do settings.json: \(url.path)", "settings.json backup: \(url.path)"))
}

func removingPsiuHooks(_ groups: [[String: Any]]) -> [[String: Any]] {
    groups.compactMap { g in
        var g = g
        let hs = (g["hooks"] as? [[String: Any]] ?? []).filter {
            !isPsiuCommand($0["command"] as? String ?? "")
        }
        if hs.isEmpty { return nil }
        g["hooks"] = hs
        return g
    }
}

public let hookEvents: [(String, String?)] = [
    ("SessionStart", nil), ("UserPromptSubmit", nil),
    ("PreToolUse", "*"), ("PostToolUse", "*"), ("PermissionRequest", "*"),
    ("Notification", "*"), ("Stop", nil), ("SessionEnd", nil), ("PreCompact", "*"),
]

/// `Psiu install`: adds Psiu's hooks and status line to Claude Code's settings.json, keeping the original as a backup.
public func runInstall(paths: PsiuPaths = .current, executable: String = executablePath) {
    paths.ensureDirectories()
    try? FileManager.default.createDirectory(at: paths.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    var (settings, rawData) = loadSettings(paths)
    backup(rawData, paths)

    let hookCommand = "\"\(executable)\" hook"
    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for (eventName, matcher) in hookEvents {
        var groups = removingPsiuHooks(hooks[eventName] as? [[String: Any]] ?? [])
        var g: [String: Any] = ["hooks": [["type": "command", "command": hookCommand]]]
        if let matcher { g["matcher"] = matcher }
        groups.append(g)
        hooks[eventName] = groups
    }
    settings["hooks"] = hooks

    var sl = settings["statusLine"] as? [String: Any] ?? [:]
    if let cmd = sl["command"] as? String, !isPsiuCommand(cmd) {
        try? cmd.write(to: paths.previousStatusLine, atomically: true, encoding: .utf8)
        print(tr("Sua status line anterior foi guardada e continua aparecendo no terminal.", "Your previous status line was saved and still shows in the terminal."))
    }
    sl["type"] = "command"
    sl["command"] = "\"\(executable)\" statusline"
    settings["statusLine"] = sl

    writeJSON(settings, to: paths.settings, pretty: true)
    print(tr("Hooks do Psiu: \(hookEvents.map { $0.0 }.joined(separator: ", ")).", "Psiu hooks: \(hookEvents.map { $0.0 }.joined(separator: ", "))."))
    print(tr("Status line do Psiu instalada. Reinicie as sessões do Claude Code abertas.", "Psiu status line installed. Restart any open Claude Code sessions."))
}

/// `Psiu uninstall`: removes Psiu's hooks and status line from settings.json; your previous status line comes back.
public func runUninstall(paths: PsiuPaths = .current) {
    var (settings, rawData) = loadSettings(paths)
    guard rawData != nil else { print(tr("Não há settings.json. Nada a desfazer.", "There is no settings.json. Nothing to undo.")); return }
    backup(rawData, paths)

    if var hooks = settings["hooks"] as? [String: Any] {
        for (eventName, _) in hookEvents {
            let groups = removingPsiuHooks(hooks[eventName] as? [[String: Any]] ?? [])
            hooks[eventName] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
    }
    if let sl = settings["statusLine"] as? [String: Any],
       isPsiuCommand(sl["command"] as? String ?? "") {
        if let prev = try? String(contentsOf: paths.previousStatusLine, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
            var newState = sl
            newState["command"] = prev
            settings["statusLine"] = newState
            print(tr("Sua status line anterior foi restaurada.", "Your previous status line was restored."))
        } else {
            settings["statusLine"] = nil
        }
    }
    writeJSON(settings, to: paths.settings, pretty: true)
    print(tr("Psiu removido do ~/.claude/settings.json.", "Psiu removed from ~/.claude/settings.json."))
}

// MARK: - First run, login and migration from Farol

/// Is Psiu already connected to Claude Code through this executable?
public func isPsiuConnected(paths: PsiuPaths = .current, executable: String = executablePath) -> Bool {
    guard let data = try? Data(contentsOf: paths.settings),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let cmd = (obj["statusLine"] as? [String: Any])?["command"] as? String else { return false }
    return cmd.contains(executable)
}

/// Does settings.json lack any of Psiu's hook events for this executable (an install from an older version)?
public func isMissingHooks(paths: PsiuPaths = .current, executable: String = executablePath) -> Bool {
    let hooks = readJSON(paths.settings)?["hooks"] as? [String: Any] ?? [:]
    return hookEvents.contains { event, _ in
        let groups = hooks[event] as? [[String: Any]] ?? []
        return !groups.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").contains(executable) }
        }
    }
}

public func hasFarol(paths: PsiuPaths = .current) -> Bool {
    FileManager.default.fileExists(atPath: paths.farol.path) || FileManager.default.fileExists(atPath: paths.farolAgent.path)
}

/// Stops Farol's login service, if it is running.
public func stopFarolService() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["bootout", "gui/\(getuid())/com.farol.app"]
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

/// Turns off Farol (the previous version) and brings its scoreboard, preferences and saved status line over to Psiu.
public func migrateFromFarol(paths: PsiuPaths = .current, executable: String = executablePath,
                             stopService: () -> Void = stopFarolService) {
    let fm = FileManager.default
    stopService()
    try? fm.removeItem(at: paths.farolAgent)
    let farolDir = paths.farol
    guard fm.fileExists(atPath: farolDir.path) else { return }
    paths.ensureDirectories()
    for name in ["placar.json", "prefs.json", "statusline-anterior.txt"] {
        let src = farolDir.appendingPathComponent(name), dst = paths.base.appendingPathComponent(name)
        if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: src, to: dst) }
    }
    try? fm.removeItem(at: farolDir)
    // Claude Code sessions opened before the switch still call ~/.farol/bin/Farol.
    // That path becomes a link to Psiu, so they keep working until they are restarted.
    try? fm.createDirectory(at: farolDir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: farolDir.appendingPathComponent("bin/Farol").path, withDestinationPath: executable)
}
