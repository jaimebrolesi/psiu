import Foundation

// MARK: - Install and uninstall in Claude Code's settings.json

let settingsURL = home.appendingPathComponent(".claude/settings.json")

func loadSettings() -> (dict: [String: Any], rawData: Data?) {
    guard let data = try? Data(contentsOf: settingsURL) else { return ([:], nil) }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        print(tr("O ~/.claude/settings.json não é um JSON válido. Nada foi alterado.", "~/.claude/settings.json is not valid JSON. Nothing was changed."))
        exit(1)
    }
    return (obj, data)
}

/// Keeps only the oldest backup: the settings.json from before Psiu (or Farol). The others are deleted.
func backup(_ data: Data?) {
    guard let data else { return }
    let dir = settingsURL.deletingLastPathComponent()
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

let hookEvents: [(String, String?)] = [
    ("SessionStart", nil), ("UserPromptSubmit", nil),
    ("PreToolUse", "*"), ("PostToolUse", "*"), ("PermissionRequest", "*"),
    ("Notification", "*"), ("Stop", nil), ("SessionEnd", nil), ("PreCompact", "*"),
]

func runInstall() {
    ensureDirs()
    try? fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var (settings, rawData) = loadSettings()
    backup(rawData)

    let hookCommand = "\"\(binPath)\" hook"
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
        try? cmd.write(to: prevStatusFile, atomically: true, encoding: .utf8)
        print(tr("Sua status line anterior foi guardada e continua aparecendo no terminal.", "Your previous status line was saved and still shows in the terminal."))
    }
    sl["type"] = "command"
    sl["command"] = "\"\(binPath)\" statusline"
    settings["statusLine"] = sl

    writeJSON(settings, to: settingsURL, pretty: true)
    print(tr("Hooks do Psiu: \(hookEvents.map { $0.0 }.joined(separator: ", ")).", "Psiu hooks: \(hookEvents.map { $0.0 }.joined(separator: ", "))."))
    print(tr("Status line do Psiu instalada. Reinicie as sessões do Claude Code abertas.", "Psiu status line installed. Restart any open Claude Code sessions."))
}

func runUninstall() {
    var (settings, rawData) = loadSettings()
    guard rawData != nil else { print(tr("Não há settings.json. Nada a desfazer.", "There is no settings.json. Nothing to undo.")); return }
    backup(rawData)

    if var hooks = settings["hooks"] as? [String: Any] {
        for (eventName, _) in hookEvents {
            let groups = removingPsiuHooks(hooks[eventName] as? [[String: Any]] ?? [])
            hooks[eventName] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks
    }
    if let sl = settings["statusLine"] as? [String: Any],
       isPsiuCommand(sl["command"] as? String ?? "") {
        if let prev = try? String(contentsOf: prevStatusFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
            var newState = sl
            newState["command"] = prev
            settings["statusLine"] = newState
            print(tr("Sua status line anterior foi restaurada.", "Your previous status line was restored."))
        } else {
            settings["statusLine"] = nil
        }
    }
    writeJSON(settings, to: settingsURL, pretty: true)
    print(tr("Psiu removido do ~/.claude/settings.json.", "Psiu removed from ~/.claude/settings.json."))
}
