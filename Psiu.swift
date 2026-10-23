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

import AppKit
import SwiftUI
import ServiceManagement

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

// MARK: - Hook mode: state of each session

/// Collapses spaces and line breaks and truncates to the given length.
func condense(_ text: String, _ max: Int) -> String {
    let singleLine = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    return singleLine.count > max ? String(singleLine.prefix(max)) + "…" : singleLine
}

/// Last useful bit of a reply: the last line with text, without markup.
func lastSnippet(_ msg: String) -> String {
    let lines = msg.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("```") && $0 != "---" }
    var lastLine = lines.last ?? ""
    lastLine = lastLine.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    while let c = lastLine.first, "#*->|".contains(c) { lastLine.removeFirst(); lastLine = lastLine.trimmingCharacters(in: .whitespaces) }
    return condense(lastLine, 220)
}

/// Terminal the session runs in (e.g. /dev/ttys003), so a click brings up the right window.
func currentTTY() -> String? {
    for pid in [getpid(), getppid()] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-o", "tty=", "-p", "\(pid)"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { continue }
        let d = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let t = (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty && !t.hasPrefix("?") { return t.hasPrefix("/dev/") ? t : "/dev/" + t }
    }
    return nil
}

func runHook() {
    ensureDirs()
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let rawID = input["session_id"] as? String else { return }
    let sid = safeID(rawID)
    guard !sid.isEmpty else { return }
    let file = sessionsDir.appendingPathComponent("\(sid).json")
    let event = input["hook_event_name"] as? String ?? ""
    let now = Date().timeIntervalSince1970

    if event == "SessionEnd" {
        try? fm.removeItem(at: file)
        try? fm.removeItem(at: sessionsDir.appendingPathComponent("\(sid).metrics.json"))
        return
    }

    var rec = readJSON(file) ?? [:]
    if rec["project"] == nil, let cwd = input["cwd"] as? String, !cwd.isEmpty {
        rec["project"] = (cwd as NSString).lastPathComponent
    }
    if rec["tty"] == nil {
        let env = ProcessInfo.processInfo.environment
        rec["bundle"] = env["__CFBundleIdentifier"]
        rec["termprog"] = env["TERM_PROGRAM"]
        rec["tty"] = currentTTY() ?? ""
    }
    let previousState = rec["state"] as? String

    var newState: String?
    switch event {
    case "SessionStart":
        newState = "idle"
        // /clear starts the session over; the SessionStart after a compaction is not counted again.
        if input["source"] as? String == "clear" { rec["compactacoes"] = 0 }
    case "PreCompact":
        rec["compactacoes"] = Int(num(rec["compactacoes"]) ?? 0) + 1
    case "UserPromptSubmit":
        newState = "running"
        let prompt = input["prompt"] as? String ?? ""
        rec["resumo"] = prompt.hasPrefix("<")
            ? tr("Retomou depois de uma tarefa em segundo plano.", "Resumed after a background task.")
            : tr("Pedido: ", "Prompt: ") + condense(prompt, 140)
    case "PreToolUse", "PostToolUse":
        newState = "running"
    case "PermissionRequest":
        newState = "awaiting"
        let tool = input["tool_name"] as? String ?? tr("uma ferramenta", "a tool")
        if let cmd = (input["tool_input"] as? [String: Any])?["command"] as? String {
            rec["resumo"] = tr("Quer permissão para \(tool): ", "Wants permission for \(tool): ") + condense(cmd, 90)
        } else {
            rec["resumo"] = tr("Quer permissão para usar \(tool).", "Wants permission to use \(tool).")
        }
    case "Notification":
        let kind = input["notification_type"] as? String ?? ""
        let msg = (input["message"] as? String ?? "").lowercased()
        if kind == "permission_prompt" || kind == "elicitation_dialog" || msg.contains("permission") {
            newState = "awaiting"
            if previousState != "awaiting", let m = input["message"] as? String { rec["resumo"] = condense(m, 140) }
        } else if kind == "idle_prompt", rec["state"] as? String == "running" {
            // You interrupted with Esc: Stop doesn't fire, so idle fixes the stuck blue.
            newState = "idle"
        }
    case "Stop":
        if let m = input["last_assistant_message"] as? String, !m.isEmpty { rec["resumo"] = lastSnippet(m) }
        // Stop lists the tasks still running (shells, monitors, subagents).
        let tasks = (input["background_tasks"] as? [[String: Any]] ?? []).filter {
            let st = $0["status"] as? String ?? "running"
            return st == "running" || st == "pending"
        }
        if tasks.isEmpty {
            newState = "done"
            rec["bg"] = nil
        } else {
            newState = "background"
            var order: [String] = []
            var counts: [String: Int] = [:]
            for t in tasks {
                let kind = t["type"] as? String ?? tr("tarefa", "task")
                if counts[kind] == nil { order.append(kind) }
                counts[kind, default: 0] += 1
            }
            rec["bg"] = order.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: ", ")
        }
    default:
        break
    }

    if let s = newState {
        if rec["state"] as? String != s { rec["since"] = now }
        rec["state"] = s
    }
    rec["updated"] = now
    writeJSON(rec, to: file)
    // Nothing on stdout: on UserPromptSubmit, anything printed here would go into Claude's context.
}

// MARK: - Statusline mode: context and plan limits

func runStatusLine() {
    ensureDirs()
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let input = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
    let now = Date().timeIntervalSince1970

    let cw = input["context_window"] as? [String: Any]
    let ctx = num(cw?["used_percentage"])
    var parts: [String] = []

    if let rawID = input["session_id"] as? String {
        var m: [String: Any] = ["updated": now]
        if let ctx { m["ctx"] = ctx }
        if let model = (input["model"] as? [String: Any])?["display_name"] as? String { m["model"] = model }
        if let dir = (input["workspace"] as? [String: Any])?["project_dir"] as? String {
            m["project"] = (dir as NSString).lastPathComponent
        }
        writeJSON(m, to: sessionsDir.appendingPathComponent("\(safeID(rawID)).metrics.json"))
    }
    if let ctx { parts.append(tr("contexto", "context") + " \(Int(ctx.rounded()))%") }

    if let rl = input["rate_limits"] as? [String: Any] {
        var limits = readJSON(limitsFile) ?? [:]
        for (limitKey, label) in [("five_hour", "5h"), ("seven_day", tr("semana", "week"))] {
            guard let w = rl[limitKey] as? [String: Any], let p = num(w["used_percentage"]) else { continue }
            limits[limitKey] = ["pct": p, "resets": num(w["resets_at"]) ?? 0]
            parts.append("\(label) \(Int(p.rounded()))%")
        }
        limits["updated"] = now
        writeJSON(limits, to: limitsFile)
    }

    // If you already had a status line, it keeps showing in place of Psiu's.
    if let prev = try? String(contentsOf: prevStatusFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", prev]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        if (try? p.run()) != nil {
            inPipe.fileHandleForWriting.write(raw)
            try? inPipe.fileHandleForWriting.close()
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            FileHandle.standardOutput.write(out)
            return
        }
    }
    print(parts.joined(separator: " | "))
}

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

// MARK: - Signal model

enum SessionState: String { case idle, running, background, awaiting, done }

enum RobotColor { case red, burnt, yellow, blue, backgroundBlue, green, dimGreen, gray }

struct Session: Identifiable, Equatable {
    let id: String
    var project: String
    var state: SessionState
    var since: Double
    var updated: Double
    var ctx: Double?
    var model: String?
    var bg: String?
    var summary: String?
    var tty: String?
    var bundle: String?
    var termprog: String?
    var compactions = 0
}

struct Scoreboard: Equatable {
    var working: Double = 0     // seconds with some agent working
    var waiting: Double = 0     // seconds with some session waiting for you
    var replyCount: Int = 0     // how many times you replied
    var replyTime: Double = 0   // sum of the times until you replied
    var burnt: Int = 0          // waiting episodes that crossed 30 min
}

let scoreboardFile = baseDir.appendingPathComponent("placar.json")

struct UsageWindow: Equatable {
    var pct: Double
    var resetsAt: Double
}

// Tune the sounds and reminder intervals here.
enum Sounds {
    static let permission = "Submarine"
    static let finished = "Glass"
    static let permissionReminderInterval: TimeInterval = 120   // repeats while it waits for you
    static let maxPermissionReminders = 15                      // at most 30 min of sounds
    static let finishedReminderInterval: TimeInterval = 180     // one extra reminder if you didn't come back
    static let panic = "Sosumi"
    static let panicInterval: TimeInterval = 60                 // repeats while Psiu panics
    static let panicAfter: TimeInterval = 600                   // waiting for you for 10 min: panic
    static let burnAfter: TimeInterval = 1800                   // 30 min: burnt, and silent
}

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var fiveHour: UsageWindow?
    @Published var week: UsageWindow?
    @Published var muted = false
    @Published var today = Scoreboard()
    @Published var weekWaiting: Double = 0
    @Published var forecast: Double?          // when the 5-hour window runs out, if that happens before it resets
    @Published var forecastHeadroom = false   // the current pace fits in the window
    @Published var panicIDs = Set<String>()   // sessions waiting for you for 10 to 30 min
    @Published var burntIDs = Set<String>()   // sessions waiting for 30 min or more
    @Published var revivingUntil: Date?       // a burnt Psiu shaking off the soot

    private var days: [String: [String: Double]] = [:]
    private var lastTick: Date?
    private var ticks = 0
    private var previouslyAwaiting: [String: Double] = [:]
    private var samples: [(t: Double, p: Double)] = []
    private var currentResets: Double = 0
    private var lastLimitsRead: Double = 0
    private var belowBurn = Set<String>()     // waiting episodes seen before 30 min, so each burn counts once
    private var panicked = Set<String>()      // waiting episodes that already played the panic sound

    init() {
        if let d = readJSON(scoreboardFile)?["dias"] as? [String: [String: Double]] { days = d }
    }

    /// A working session (or one running background tasks) is above 80% of its context.
    var heavyContext: Bool {
        sessions.contains { ($0.state == .running || $0.state == .background) && ($0.ctx ?? 0) >= 80 }
    }
    /// A compacted session finished and you haven't seen it yet: the green Psiu wears a purple headband.
    var bandaged: Bool {
        sessions.contains { $0.state == .done && $0.compactions > 0 && !seen.contains(sessionKey($0)) }
    }
    var greenDot: Bool {
        color != .green && sessions.contains { $0.state == .done && !seen.contains(sessionKey($0)) }
    }

    private var seen = Set<String>()
    private var known = Set<String>()
    private var lastSound: [String: Date] = [:]
    private var reminders: [String: Int] = [:]
    private var firstLoad = true

    func sessionKey(_ s: Session) -> String { "\(s.id)|\(s.state.rawValue)|\(Int(s.since))" }

    var color: RobotColor {
        if !panicIDs.isEmpty { return .red }
        if !burntIDs.isEmpty { return .burnt }
        if sessions.contains(where: { $0.state == .awaiting }) { return .yellow }
        if sessions.contains(where: { $0.state == .running }) { return .blue }
        if sessions.contains(where: { $0.state == .background }) { return .backgroundBlue }
        if sessions.contains(where: { $0.state == .done && !seen.contains(sessionKey($0)) }) { return .green }
        return sessions.isEmpty ? .gray : .dimGreen
    }

    func reload() {
        let now = Date().timeIntervalSince1970
        var list: [Session] = []
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".metrics.json") {
            guard let r = readJSON(url) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let metricsURL = sessionsDir.appendingPathComponent("\(id).metrics.json")
            let updated = num(r["updated"]) ?? 0
            if now - updated > 12 * 3600 {   // session abandoned for more than 12 h
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: metricsURL)
                continue
            }
            var s = Session(id: id,
                           project: r["project"] as? String ?? tr("sessão", "session"),
                           state: SessionState(rawValue: r["state"] as? String ?? "") ?? .idle,
                           since: num(r["since"]) ?? updated,
                           updated: updated,
                           bg: r["bg"] as? String,
                           summary: r["resumo"] as? String,
                           tty: r["tty"] as? String,
                           bundle: r["bundle"] as? String,
                           termprog: r["termprog"] as? String,
                           compactions: Int(num(r["compactacoes"]) ?? 0))
            if let m = readJSON(metricsURL) {
                s.ctx = num(m["ctx"])
                s.model = m["model"] as? String
                if r["project"] == nil, let p = m["project"] as? String { s.project = p }
            }
            list.append(s)
        }
        list.sort { $0.since > $1.since }
        if list != sessions { sessions = list }
        updateWaitLevels(now)

        if let l = readJSON(limitsFile) {
            let c = usageWindow(l["five_hour"], now), w = usageWindow(l["seven_day"], now)
            if c != fiveHour { fiveHour = c }
            if w != week { week = w }
            recordSample(l)
        }
        updateScoreboard(Date())
        playSoundsIfNeeded()
        firstLoad = false
    }

    // MARK: Panic and burnt Psiu

    private func updateWaitLevels(_ now: Double) {
        var panic = Set<String>(), burnt = Set<String>()
        for s in sessions where s.state == .awaiting {
            let waited = now - s.since
            if waited >= Sounds.burnAfter { burnt.insert(s.id) } else if waited >= Sounds.panicAfter { panic.insert(s.id) }
        }
        // A burnt Psiu whose session stopped waiting shakes off the soot before taking the new state.
        let revived = burntIDs.subtracting(burnt).contains { id in
            sessions.contains { $0.id == id && $0.state != .awaiting }
        }
        if revived { revivingUntil = Date().addingTimeInterval(0.8) }
        if panic != panicIDs { panicIDs = panic }
        if burnt != burntIDs { burntIDs = burnt }
    }

    // MARK: 5-hour window forecast

    private func recordSample(_ l: [String: Any]) {
        guard let readAt = num(l["updated"]), readAt != lastLimitsRead,
              let fh = l["five_hour"] as? [String: Any], let p = num(fh["pct"]) else { return }
        lastLimitsRead = readAt
        let r = num(fh["resets"]) ?? 0
        if r != currentResets { samples = []; currentResets = r }
        samples.append((readAt, p))
        samples = samples.filter { readAt - $0.t <= 3600 }   // pace over the last hour

        var overflow: Double?
        var headroom = false
        if let a = samples.first, let b = samples.last, b.t - a.t >= 300 {
            if b.p > a.p {
                let rate = (b.p - a.p) / (b.t - a.t)
                let fullAt = b.t + (100 - b.p) / rate
                if currentResets > 0 && fullAt < currentResets { overflow = fullAt } else { headroom = true }
            } else {
                headroom = true
            }
        }
        if overflow != forecast { forecast = overflow }
        if headroom != forecastHeadroom { forecastHeadroom = headroom }
    }

    // MARK: Today's scoreboard

    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    private func updateScoreboard(_ now: Date) {
        let dt = min(lastTick.map { now.timeIntervalSince($0) } ?? 0, 2)
        lastTick = now
        let day = dayKey(now)
        var d = days[day] ?? [:]
        if sessions.contains(where: { $0.state == .running || $0.state == .background }) { d["trab", default: 0] += dt }
        if sessions.contains(where: { $0.state == .awaiting }) { d["esp", default: 0] += dt }

        var awaitingNow: [String: Double] = [:]
        for s in sessions where s.state == .awaiting { awaitingNow[sessionKey(s)] = s.since }
        for (k, since) in previouslyAwaiting where awaitingNow[k] == nil {
            d["nResp", default: 0] += 1
            d["tResp", default: 0] += max(0, now.timeIntervalSince1970 - since)
        }
        previouslyAwaiting = awaitingNow
        // Each waiting episode that crosses 30 min burns one Psiu, counted once.
        for s in sessions where s.state == .awaiting {
            let k = sessionKey(s)
            if now.timeIntervalSince1970 - s.since < Sounds.burnAfter { belowBurn.insert(k) }
            else if belowBurn.remove(k) != nil { d["queim", default: 0] += 1 }
        }
        belowBurn.formIntersection(awaitingNow.keys)
        days[day] = d

        let last7Days = (0..<7).map { dayKey(now.addingTimeInterval(-Double($0) * 86400)) }
        days = days.filter { last7Days.contains($0.key) }
        let h = Scoreboard(working: (d["trab"] ?? 0).rounded(), waiting: (d["esp"] ?? 0).rounded(),
                       replyCount: Int(d["nResp"] ?? 0), replyTime: d["tResp"] ?? 0, burnt: Int(d["queim"] ?? 0))
        if h != today { today = h }
        let weekWait = last7Days.reduce(0) { $0 + (days[$1]?["esp"] ?? 0) }.rounded()
        if weekWait != weekWaiting { weekWaiting = weekWait }

        ticks += 1
        if ticks >= 20 {   // saves every ~10 s
            ticks = 0
            writeJSON(["dias": days], to: scoreboardFile)
        }
    }

    private func usageWindow(_ v: Any?, _ now: Double) -> UsageWindow? {
        guard let d = v as? [String: Any], let p = num(d["pct"]) else { return nil }
        let r = num(d["resets"]) ?? 0
        if r > 0 && r < now { return UsageWindow(pct: 0, resetsAt: 0) }   // the window has already reset
        return UsageWindow(pct: p, resetsAt: r)
    }

    private func playSoundsIfNeeded() {
        let now = Date()
        let active = Set(sessions.map(sessionKey))
        for s in sessions {
            let k = sessionKey(s)
            let isNew = !known.contains(k)
            known.insert(k)
            if firstLoad {
                lastSound[k] = now
                reminders[k] = 99
                if s.state == .awaiting && now.timeIntervalSince1970 - s.since >= Sounds.panicAfter { panicked.insert(k) }
                continue
            }
            if seen.contains(k) { continue }
            let n = reminders[k] ?? 0
            switch s.state {
            case .awaiting:
                let waited = now.timeIntervalSince1970 - s.since
                if waited >= Sounds.burnAfter { break }   // burnt: silent
                if waited >= Sounds.panicAfter {
                    if panicked.insert(k).inserted { playSound(Sounds.panic, k) }
                    else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.panicInterval { playSound(Sounds.panic, k) }
                } else if isNew { playSound(Sounds.permission, k) }
                else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.permissionReminderInterval,
                        n < Sounds.maxPermissionReminders {
                    playSound(Sounds.permission, k); reminders[k] = n + 1
                }
            case .done:
                // Waits 3 s: if another task wakes Claude right after, it doesn't play for nothing.
                if lastSound[k] == nil {
                    if now.timeIntervalSince1970 - s.since >= 3 { playSound(Sounds.finished, k) }
                } else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.finishedReminderInterval, n < 1 {
                    playSound(Sounds.finished, k); reminders[k] = n + 1
                }
            default:
                break
            }
        }
        known.formIntersection(active)
        seen.formIntersection(active)
        panicked.formIntersection(active)
        lastSound = lastSound.filter { active.contains($0.key) }
        reminders = reminders.filter { active.contains($0.key) }
    }

    private func playSound(_ name: String, _ k: String) {
        lastSound[k] = Date()
        if !muted { NSSound(named: NSSound.Name(name))?.play() }
    }

    /// Opening the panel counts as "seen" for the sound reminders.
    func acknowledge() {
        for s in sessions where s.state == .done || s.state == .awaiting { seen.insert(sessionKey(s)) }
        objectWillChange.send()
    }
}

// MARK: - Notch window

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Host: NSHostingView<PillView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Geometry and open state of a panel (one per screen).
@MainActor
final class PanelGeometry: ObservableObject {
    @Published var isOpen = false
    @Published var w: CGFloat = 230   // closed: notch width + ears
    @Published var h: CGFloat = 32    // closed: menu bar height
    @Published var W: CGFloat = 330   // open
    @Published var H: CGFloat = 260
    var screenFrame: NSRect = .zero

    /// Closed: extra width on each side while a dot is lit, so the dot clears the physical notch.
    @Published var dotsRoom: CGFloat = 0
    var hasNotch = false
    /// Closed width, with room for the dots when needed.
    var closedWidth: CGFloat { w + 2 * dotsRoom }
    /// A dot (5) and its gap to the robot (6), plus 3 so it doesn't touch the notch's edge.
    static let dotsRoomWidth: CGFloat = 14

    /// Open, the top strip grows to this height so Psiu can be bigger.
    static let openStripHeight: CGFloat = 44
    /// Height of the top strip, closed or open.
    var stripHeight: CGFloat { isOpen ? max(h, Self.openStripHeight) : h }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var panels: [CGDirectDisplayID: (panel: NotchPanel, host: Host, geo: PanelGeometry)] = [:]
    var timer: Timer?
    var clickMonitor: Any?
    var hiddenScreens = Set<String>()
    let springAnimation = Animation.spring(response: 0.45, dampingFraction: 0.86)

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureDirs()
        let prefs = readJSON(prefsFile) ?? [:]
        store.muted = prefs["mudo"] as? Bool ?? false
        hiddenScreens = Set(prefs["ocultas"] as? [String] ?? [])

        syncPanels()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPanels() }
        }
        // A click in any other app collapses the panel.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeAll() }
        }
        store.reload()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.store.reload()
                self?.updateDotsRoom()
                self?.checkDemo()
            }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.checkInstallation() }
        }
    }

    // MARK: Demo (used by record-demo.sh)

    var openedByDemo = false

    func checkDemo() {
        let requested = fm.fileExists(atPath: baseDir.appendingPathComponent("demo-panel").path)
        if requested && !openedByDemo {
            let mainID = NSScreen.screens.first.map { displayID($0) }
            if let id = mainID.flatMap({ panels[$0] != nil ? $0 : nil }) ?? panels.keys.first {
                if panels[id]?.geo.isOpen == false { toggleDetail(id) }
                openedByDemo = true
            }
        } else if !requested && openedByDemo {
            closeAll()
            openedByDemo = false
        }
    }

    // MARK: Installation

    func showAlert(_ title: String, _ text: String, buttons: [String] = ["OK"]) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func checkInstallation() {
        if binPath.hasPrefix("/Volumes/") || binPath.contains("/AppTranslocation/") {
            _ = showAlert(tr("Arraste o Psiu para Aplicativos", "Drag Psiu to Applications"),
                      tr("Ele está rodando de dentro do instalador. Arraste o Psiu para a pasta Aplicativos e abra de lá.",
                         "It's running from inside the installer. Drag Psiu to the Applications folder and open it from there."))
            NSApp.terminate(nil)
            return
        }
        if isPsiuConnected() {
            // Installs from older versions lack newer hook events: add them quietly (the original backup is kept).
            if isMissingHooks() { runInstall() }
            return
        }
        var text = tr("O Psiu grava os hooks e a status line em ~/.claude/settings.json, guardando um backup do original, e passa a abrir quando você entra no Mac. Nada sai do seu computador.",
                       "Psiu adds its hooks and status line to ~/.claude/settings.json, keeping a backup of the original, and opens when you log in to your Mac. Nothing leaves your computer.")
        if hasFarol { text += tr("\n\nO Farol, a versão anterior, será desligado e substituído. O placar e as preferências vêm junto.",
                                  "\n\nFarol, the previous version, will be turned off and replaced. Your scoreboard and preferences come along.") }
        guard showAlert(tr("Ligar o Psiu ao Claude Code?", "Connect Psiu to Claude Code?"), text,
                    buttons: [tr("Ligar", "Connect"), tr("Agora não", "Not now")]) == 0 else { return }
        migrateFromFarol()
        runInstall()
        var doneMessage = tr("Reinicie as sessões do Claude Code que estiverem abertas.", "Restart any Claude Code sessions that are open.")
        do {
            try SMAppService.mainApp.register()
            if SMAppService.mainApp.status == .requiresApproval {
                doneMessage += tr("\n\nPara ele abrir no login, autorize o Psiu em Ajustes do Sistema → Geral → Itens de Início.",
                          "\n\nTo open it at login, allow Psiu in System Settings → General → Login Items.")
            }
        } catch {
            doneMessage += tr("\n\nNão consegui registrar a abertura no login: ", "\n\nCouldn't register open at login: ") + error.localizedDescription
        }
        _ = showAlert(tr("Psiu ligado", "Psiu is connected"), doneMessage)
    }

    func uninstall() {
        let r = showAlert(tr("Desinstalar o Psiu?", "Uninstall Psiu?"),
                      tr("Removo os hooks e a status line do Claude Code (a sua status line anterior volta) e tiro o Psiu do login. Depois, é só arrastar o Psiu de Aplicativos para o Lixo.",
                         "I'll remove the hooks and status line from Claude Code (your previous status line comes back) and take Psiu out of your login items. Then just drag Psiu from Applications to the Trash."),
                      buttons: [tr("Desinstalar", "Uninstall"), tr("Cancelar", "Cancel")])
        guard r == 0 else { return }
        runUninstall()
        try? SMAppService.mainApp.unregister()
        try? fm.removeItem(at: baseDir)
        try? fm.removeItem(at: home.appendingPathComponent(".farol"))
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    // MARK: Screens

    var screenNames: [String] { NSScreen.screens.map(\.localizedName) }

    func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    func notchWidth(_ screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0,
              let e = screen.auxiliaryTopLeftArea, let d = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, screen.frame.width - e.width - d.width)
    }

    /// On screens without a notch, Psiu mimics the MacBook's notch (or 185 points if no MacBook screen is on).
    var defaultNotchWidth: CGFloat {
        NSScreen.screens.map { notchWidth($0) }.first(where: { $0 > 0 }) ?? 185
    }

    func isScreenVisible(_ name: String) -> Bool { !hiddenScreens.contains(name) }

    func toggleScreen(_ name: String) {
        if isScreenVisible(name) {
            let remaining = screenNames.filter { isScreenVisible($0) && $0 != name }
            guard !remaining.isEmpty else { return }   // never hides from every screen
            hiddenScreens.insert(name)
        } else {
            hiddenScreens.remove(name)
        }
        savePrefs()
        syncPanels()
    }

    func savePrefs() {
        writeJSON(["mudo": store.muted, "ocultas": Array(hiddenScreens)], to: prefsFile)
    }

    func makePanel(_ id: CGDirectDisplayID) -> (panel: NotchPanel, host: Host, geo: PanelGeometry) {
        let p = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 24),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.hidesOnDeactivate = false
        let geo = PanelGeometry()
        let h = Host(rootView: PillView(store: store, app: self, displayID: id, geo: geo))
        p.contentView = h
        return (p, h, geo)
    }

    func syncPanels() {
        var presentIDs = Set<CGDirectDisplayID>()
        for screen in NSScreen.screens {
            let id = displayID(screen)
            guard isScreenVisible(screen.localizedName) else { continue }
            presentIDs.insert(id)
            let entry = panels[id] ?? makePanel(id)
            panels[id] = entry
            place(entry, on: screen)
            entry.panel.orderFrontRegardless()
        }
        for (id, entry) in Array(panels) where !presentIDs.contains(id) {
            entry.panel.orderOut(nil)
            panels[id] = nil
        }
    }

    func place(_ entry: (panel: NotchPanel, host: Host, geo: PanelGeometry), on screen: NSScreen) {
        let f = screen.frame
        let notch = notchWidth(screen)
        let menuBarHeight = f.maxY - screen.visibleFrame.maxY
        entry.geo.screenFrame = f
        entry.geo.h = notch > 0 ? screen.safeAreaInsets.top : (menuBarHeight >= 20 ? menuBarHeight : 24)
        entry.geo.w = (notch > 0 ? notch : defaultNotchWidth) + 2 * 46
        entry.geo.hasNotch = notch > 0
        entry.geo.dotsRoom = dotsRoom(for: entry.geo)
        applyFrame(entry)
    }

    /// On screens with a physical notch, the closed notch widens while a dot is lit; elsewhere the dot is already visible.
    func dotsRoom(for geo: PanelGeometry) -> CGFloat {
        geo.hasNotch && store.greenDot ? PanelGeometry.dotsRoomWidth : 0
    }

    func updateDotsRoom() {
        for (id, entry) in panels {
            let target = dotsRoom(for: entry.geo)
            guard entry.geo.dotsRoom != target else { continue }
            if entry.geo.isOpen {   // the open panel doesn't depend on it
                entry.geo.dotsRoom = target
            } else if target > entry.geo.dotsRoom {
                // Growing: first the window (transparent), then the notch stretches inside it.
                let g = entry.geo, w = g.w + 2 * target
                entry.panel.setFrame(NSRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - g.h, width: w, height: g.h), display: true)
                withAnimation(springAnimation) { entry.geo.dotsRoom = target }
            } else {
                // Shrinking: the notch first, then the window.
                withAnimation(springAnimation) { entry.geo.dotsRoom = target }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let entry = self.panels[id], !entry.geo.isOpen else { return }
                        self.applyFrame(entry)
                    }
                }
            }
        }
    }

    /// Closed, the window is the size of the notch; open, the size of the panel. Always at the top, centered.
    func applyFrame(_ entry: (panel: NotchPanel, host: Host, geo: PanelGeometry)) {
        let g = entry.geo
        let w = g.isOpen ? g.W : g.closedWidth
        let h = g.isOpen ? g.H : g.h
        entry.panel.setFrame(NSRect(x: g.screenFrame.midX - w / 2, y: g.screenFrame.maxY - h, width: w, height: h), display: true)
    }

    func toggleDetail(_ id: CGDirectDisplayID) {
        guard let entry = panels[id] else { return }
        if entry.geo.isOpen { closePanel(id); return }
        closeAll()
        store.acknowledge()
        let lines = CGFloat(min(max(store.sessions.count, 1), 5))
        let tips = CGFloat(store.sessions.prefix(5).filter { $0.state == .done && $0.compactions > 0 }.count)
        entry.geo.W = max(entry.geo.closedWidth, 340)
        entry.geo.H = max(entry.geo.h, PanelGeometry.openStripHeight) + 156 + 112 + 70 * lines + 16 * tips + (store.today.burnt > 0 ? 18 : 0)
        // First the window grows (transparent), then the notch stretches inside it.
        let g = entry.geo
        entry.panel.setFrame(NSRect(x: g.screenFrame.midX - g.W / 2, y: g.screenFrame.maxY - g.H, width: g.W, height: g.H), display: true)
        withAnimation(springAnimation) { entry.geo.isOpen = true }
    }

    func closePanel(_ id: CGDirectDisplayID) {
        guard let entry = panels[id], entry.geo.isOpen else { return }
        withAnimation(springAnimation) { entry.geo.isOpen = false }
        // After the notch collapses, the window goes back to the notch size and frees the menu bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let entry = self.panels[id], !entry.geo.isOpen else { return }
                self.applyFrame(entry)
            }
        }
    }

    func closeAll() {
        for id in panels.keys { closePanel(id) }
    }

    // MARK: Open the session's terminal

    func openTerminal(_ s: Session) {
        closeAll()
        let bundle = s.bundle ?? ""
        let prog = s.termprog ?? ""
        if let tty = s.tty, !tty.isEmpty {
            if bundle == "com.apple.Terminal" || prog == "Apple_Terminal" {
                if runAppleScript(scriptTerminal(tty)) { return }
            }
            if bundle == "com.googlecode.iterm2" || prog == "iTerm.app" {
                if runAppleScript(scriptITerm(tty)) { return }
            }
        }
        // Others (VS Code, Cursor, Ghostty, Warp...): bring the app to the front.
        if !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func runAppleScript(_ script: String) -> Bool {
        var errorInfo: NSDictionary?
        let r = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        return errorInfo == nil && r?.booleanValue == true
    }

    func scriptTerminal(_ tty: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    func scriptITerm(_ tty: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }
}

// MARK: - Visuals

func swiftUIColor(_ c: RobotColor) -> Color {
    switch c {
    case .red: return Color(hex: 0xE24B4A)
    case .burnt: return Color(hex: 0x554A43)
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

struct PillView: View {
    @ObservedObject var store: Store
    let app: AppDelegate
    let displayID: CGDirectDisplayID
    @ObservedObject var geo: PanelGeometry

    var radius: CGFloat { geo.isOpen ? 24 : 9 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius).fill(Color.black)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        usage
                        Spacer(minLength: 0)
                        if store.greenDot { Circle().fill(Color(hex: 0x97C459)).frame(width: 5, height: 5) }
                        // Peeking, the robot rests on the bottom of the strip: the clipping edge matches the notch's edge.
                        let peeking = store.color == .backgroundBlue && !geo.isOpen
                        RobotView(color: store.color, tired: store.heavyContext, peeking: peeking,
                                  bandaged: store.bandaged, revivingUntil: store.revivingUntil)
                            .frame(width: geo.isOpen ? 42 : 29, height: geo.isOpen ? 32 : 22)
                            .frame(maxHeight: .infinity, alignment: peeking ? .bottom : .center)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: geo.stripHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { app.toggleDetail(displayID) }

                    if geo.isOpen {
                        DetailView(store: store, onOpen: { app.openTerminal($0) })
                            .environment(\.colorScheme, .dark)
                            .padding(.horizontal, 6)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: -6))
                                    .animation(.easeOut(duration: 0.28).delay(0.14)),
                                removal: .opacity.animation(.easeIn(duration: 0.1))))
                    }
                }
            }
            .frame(width: geo.isOpen ? geo.W : geo.closedWidth, height: geo.isOpen ? geo.H : geo.h)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius))
            .overlay {
                if store.color == .red {
                    // Panic: a red edge pulses around the notch.
                    TimelineView(.animation) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                            .strokeBorder(Color(hex: 0xE24B4A), lineWidth: 1.75)
                            .opacity(0.625 + 0.375 * sin(2 * .pi * t / 1.2))
                    }
                    .allowsHitTesting(false)
                }
            }
            .contextMenu {
                Menu(tr("Mostrar em", "Show on")) {
                    ForEach(app.screenNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(
                            get: { app.isScreenVisible(name) },
                            set: { _ in app.toggleScreen(name) }))
                    }
                }
                Toggle(tr("Silenciar sons", "Mute sounds"), isOn: Binding(
                    get: { store.muted },
                    set: { store.muted = $0; app.savePrefs() }))
                Button(tr("Testar sons", "Test sounds")) {
                    NSSound(named: NSSound.Name(Sounds.permission))?.play()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        NSSound(named: NSSound.Name(Sounds.finished))?.play()
                    }
                }
                Divider()
                Button(tr("Sair do Psiu", "Quit Psiu")) { NSApp.terminate(nil) }
                Button(tr("Desinstalar o Psiu…", "Uninstall Psiu…")) { app.uninstall() }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder var usage: some View {
        if let c = store.fiveHour {
            Text("\(Int(c.pct.rounded()))%")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(c.pct >= 75 ? usageColor(c.pct) : Color.white.opacity(0.75))
        }
    }
}

// MARK: - Robot

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Robot head with LED eyes. Drawn on a 60 x 46 grid.
struct RobotView: View {
    let color: RobotColor
    var tired = false
    /// Background state with the panel closed: sunk into the notch, only the top half of the head shows.
    var peeking = false
    /// A compacted session finished: the green Psiu wears a purple headband.
    var bandaged = false
    /// Until when a burnt Psiu is shaking off the soot (0.8 s).
    var revivingUntil: Date? = nil

    /// Room around the grid, so smoke and soot can leave the head without being cut.
    private let margin: CGFloat = 8

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let left = revivingUntil.map { $0.timeIntervalSince(ctx.date) } ?? 0
            let revival = left > 0 && left <= 0.8 ? 1 - left / 0.8 : nil
            Canvas { g, size in
                g.translateBy(x: margin, y: margin)
                drawRobot(&g, CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin),
                          color, tired, t, peeking: peeking, bandaged: bandaged, revival: revival)
            }
            .padding(-margin)
        }
        .aspectRatio(60.0 / 46.0, contentMode: .fit)
    }
}

/// Builds a path from SVG path data with absolute M, C and Z commands.
private func svgPath(_ d: String) -> Path {
    let tokens = d.map { $0.isLetter ? " \($0) " : String($0) }.joined().split(separator: " ")
    var p = Path(), i = 0, command: Character = "M"
    func number() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
    func point() -> CGPoint { let x = number(); return CGPoint(x: x, y: number()) }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter {
            command = c; i += 1
            if command == "Z" { p.closeSubpath() }
            continue
        }
        switch command {
        case "M": p.move(to: point())
        case "C":
            let c1 = point(), c2 = point()
            p.addCurve(to: point(), control1: c1, control2: c2)
        default: i += 1
        }
    }
    return p
}

/// The eyes on fire of the panic state, on the 60 x 46 grid.
private enum Flames {
    static let left = svgPath("M20.5 12 C24.5 17.5 28.2 21 28.2 26.8 C28.2 31.2 24.8 34 20.5 34 C16.2 34 12.8 31.2 12.8 26.8 C12.8 23 15 20.8 16.4 18.4 C17 21 18 22.4 19.2 22.8 C18.8 19.2 19.3 15.6 20.5 12 Z")
    static let leftCore = svgPath("M20.5 20 C22.8 23.2 24.8 25.2 24.8 28.4 C24.8 31.2 22.8 33 20.5 33 C18.2 33 16.2 31.2 16.2 28.4 C16.2 25.8 18.2 23.4 20.5 20 Z")
    static let right = svgPath("M39.5 12 C40.7 15.6 41.2 19.2 40.8 22.8 C42 22.4 43 21 43.6 18.4 C45 20.8 47.2 23 47.2 26.8 C47.2 31.2 43.8 34 39.5 34 C35.2 34 31.8 31.2 31.8 26.8 C31.8 21 35.5 17.5 39.5 12 Z")
    static let rightCore = svgPath("M39.5 20 C41.8 23.4 43.8 25.8 43.8 28.4 C43.8 31.2 41.8 33 39.5 33 C37.2 33 35.2 31.2 35.2 28.4 C35.2 25.2 37.2 23.2 39.5 20 Z")
}

/// Mixes two 0xRRGGBB colors, from a (f = 0) to b (f = 1).
private func mix(_ a: UInt32, _ b: UInt32, _ f: Double, alpha: Double) -> Color {
    func channel(_ c: UInt32, _ shift: UInt32) -> Double { Double((c >> shift) & 0xFF) / 255 }
    func blend(_ shift: UInt32) -> Double { channel(a, shift) + (channel(b, shift) - channel(a, shift)) * f }
    return Color(.sRGB, red: blend(16), green: blend(8), blue: blend(0), opacity: alpha)
}

private func phase(_ t: Double, _ period: Double) -> Double {
    t.truncatingRemainder(dividingBy: period) / period
}

private func pill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat,
                      scaleY: CGFloat = 1, dx: CGFloat = 0) -> Path {
    let nh = h * scaleY
    let cy = y + h / 2
    return Path(roundedRect: CGRect(x: x + dx, y: cy - nh / 2, width: w, height: nh),
                cornerRadius: min(r, nh / 2))
}

private func headShape() -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 30, y: 6.5))
    p.addCurve(to: CGPoint(x: 55, y: 25), control1: CGPoint(x: 46, y: 6.5), control2: CGPoint(x: 55, y: 13))
    p.addCurve(to: CGPoint(x: 30, y: 43), control1: CGPoint(x: 55, y: 37), control2: CGPoint(x: 46, y: 43))
    p.addCurve(to: CGPoint(x: 5, y: 25), control1: CGPoint(x: 14, y: 43), control2: CGPoint(x: 5, y: 37))
    p.addCurve(to: CGPoint(x: 30, y: 6.5), control1: CGPoint(x: 5, y: 13), control2: CGPoint(x: 14, y: 6.5))
    p.closeSubpath()
    return p
}

private func visorShape() -> Path {
    var p = Path()
    p.move(to: CGPoint(x: 30, y: 9.2))
    p.addCurve(to: CGPoint(x: 52.3, y: 25), control1: CGPoint(x: 44, y: 9.2), control2: CGPoint(x: 52.3, y: 14.8))
    p.addCurve(to: CGPoint(x: 30, y: 40.3), control1: CGPoint(x: 52.3, y: 35.2), control2: CGPoint(x: 44, y: 40.3))
    p.addCurve(to: CGPoint(x: 7.7, y: 25), control1: CGPoint(x: 16, y: 40.3), control2: CGPoint(x: 7.7, y: 35.2))
    p.addCurve(to: CGPoint(x: 30, y: 9.2), control1: CGPoint(x: 7.7, y: 14.8), control2: CGPoint(x: 16, y: 9.2))
    p.closeSubpath()
    return p
}

/// Eyes drooping with tiredness (heavy context, purple Psiu), with a drop of sweat on the side.
private func tiredEyes(_ g: inout GraphicsContext, _ led: Color, dx: CGFloat, _ t: Double) {
    let droop = CGFloat(1 - 0.1 * (1 - cos(2 * .pi * t / 2.6)) / 2)
    for (cx, angle) in [(CGFloat(20.5), -7.0), (CGFloat(39.5), 7.0)] {
        var gg = g
        gg.translateBy(x: cx + dx, y: 26.5)
        gg.rotate(by: .degrees(angle))
        gg.fill(pill(-6.5, -5, 13, 10, 4.4, scaleY: droop), with: .color(led))
    }
    let p = phase(t, 1.6)
    let y = CGFloat(-2 + 11 * p)
    let fade = p < 0.2 ? p / 0.2 : (p > 0.8 ? (1 - p) / 0.2 : 1)
    var drop = Path()
    drop.move(to: CGPoint(x: 53, y: 7 + y))
    drop.addCurve(to: CGPoint(x: 57, y: 14.8 + y), control1: CGPoint(x: 56, y: 11 + y), control2: CGPoint(x: 57, y: 13 + y))
    drop.addCurve(to: CGPoint(x: 53, y: 18.4 + y), control1: CGPoint(x: 57, y: 17 + y), control2: CGPoint(x: 55.2, y: 18.4 + y))
    drop.addCurve(to: CGPoint(x: 49, y: 14.8 + y), control1: CGPoint(x: 50.8, y: 18.4 + y), control2: CGPoint(x: 49, y: 17 + y))
    drop.addCurve(to: CGPoint(x: 53, y: 7 + y), control1: CGPoint(x: 49, y: 13 + y), control2: CGPoint(x: 50, y: 11 + y))
    g.fill(drop, with: .color(Color(hex: 0xEEEDFE, alpha: fade)))
}

private func drawRobot(_ g: inout GraphicsContext, _ size: CGSize, _ color: RobotColor, _ tired: Bool, _ t: Double,
                          peeking: Bool = false, bandaged: Bool = false, revival: Double? = nil) {
    let s = min(size.width / 60, size.height / 46)
    g.translateBy(x: (size.width - 60 * s) / 2, y: (size.height - 46 * s) / 2)
    g.scaleBy(x: s, y: s)
    if peeking { g.clip(to: Path(CGRect(x: 0, y: 0, width: 60, height: 46))) }

    // Shell and LED colors per state.
    let shellHex: UInt32, shellAlpha: Double, led: Color
    switch color {
    case .red: shellHex = 0xF09595; shellAlpha = 1; led = Color(hex: 0xFFD27A)
    case .burnt: shellHex = 0x554A43; shellAlpha = 1; led = Color(hex: 0xD3D1C7)
    case .blue where tired, .backgroundBlue where tired:   // heavy work: purple and tired
        shellHex = 0xAFA9EC; shellAlpha = 1; led = Color(hex: 0xCECBF6)
    case .blue, .backgroundBlue: shellHex = 0x85B7EB; shellAlpha = 1; led = Color(hex: 0xA9D2FF)
    case .yellow: shellHex = 0xFAC775; shellAlpha = 1; led = Color(hex: 0xFFD27A)
    case .green: shellHex = 0xC0DD97; shellAlpha = 1; led = Color(hex: 0xC7EE8F)
    case .dimGreen: shellHex = 0xC0DD97; shellAlpha = 0.5; led = Color(hex: 0xC7EE8F, alpha: 0.5)
    case .gray: shellHex = 0x888780; shellAlpha = 1; led = Color(hex: 0xD3D1C7)
    }
    // Reviving, the shell goes from burnt to the new state's color.
    let shell = revival.map { mix(0x554A43, shellHex, $0, alpha: 1 + (shellAlpha - 1) * $0) }
        ?? Color(hex: shellHex, alpha: shellAlpha)

    // Head movement.
    var dy = 0.0, tilt = 0.0, sway = 0.0
    switch color {
    case .red:
        let w = 2 * .pi * t / 0.32
        sway = 1.4 * sin(w)
        tilt = 4 * sin(w + .pi / 2)
    case .burnt:
        tilt = -5 + sin(2 * .pi * t / 3)
    case .yellow:
        let w = sin(2 * .pi * t / 0.9)
        tilt = 5 * w
        dy = -3 * abs(w)
    case .green:
        let p = phase(t, 1.5)
        dy = p < 0.6 ? -5 * sin(.pi * p / 0.6) : 0
    case .gray:
        dy = 1.5 * (1 - cos(2 * .pi * t / 3.2)) / 2
    case .backgroundBlue where peeking:
        let p = phase(t, 5)
        // rests at the bottom, rises between 38% and 48%, stays up until 68%, goes down by 78%
        let rise: Double = p < 0.38 ? 0 : p < 0.48 ? (1 - cos(.pi * (p - 0.38) / 0.10)) / 2 : p < 0.68 ? 1 : p < 0.78 ? (1 + cos(.pi * (p - 0.68) / 0.10)) / 2 : 0
        dy = 21 - 4.5 * rise
    default:
        break
    }
    // Reviving: shakes off the soot at 10 Hz, settling down to still.
    if let p = revival { tilt += 6 * sin(2 * .pi * 10 * t) * (1 - p) }
    g.translateBy(x: 30 + sway, y: 25 + dy)
    g.rotate(by: .degrees(tilt))
    g.translateBy(x: -30, y: -25)

    g.fill(headShape(), with: .color(shell))
    if color == .burnt && s > 1 {   // soot streaks, only at large sizes
        var soot = Path()
        for (a, b) in [((9.5, 13.5), (13.5, 9.8)), ((33.0, 7.2), (38.5, 8.4)), ((50.8, 31.0), (53.4, 27.0))] {
            soot.move(to: CGPoint(x: a.0, y: a.1)); soot.addLine(to: CGPoint(x: b.0, y: b.1))
        }
        g.stroke(soot, with: .color(Color(hex: 0x2C2622)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
    }
    g.fill(visorShape(), with: .color(Color(hex: 0x141414)))
    if bandaged && color == .green {   // compacted along the way: a purple headband
        var band = g
        band.clip(to: headShape())
        band.fill(Path(CGRect(x: 0, y: 4, width: 60, height: 11)), with: .color(Color(hex: 0xAFA9EC)))
        var stripes = Path()
        stripes.move(to: CGPoint(x: 0, y: 8)); stripes.addLine(to: CGPoint(x: 60, y: 11.5))
        stripes.move(to: CGPoint(x: 0, y: 11.5)); stripes.addLine(to: CGPoint(x: 60, y: 8))
        band.stroke(stripes, with: .color(Color(hex: 0x8F88D8)), lineWidth: 0.9)
        var ends = Path()
        ends.move(to: CGPoint(x: 52.5, y: 10.5)); ends.addQuadCurve(to: CGPoint(x: 59.5, y: 5.5), control: CGPoint(x: 57, y: 7))
        ends.move(to: CGPoint(x: 52.5, y: 12)); ends.addQuadCurve(to: CGPoint(x: 59, y: 17.5), control: CGPoint(x: 57, y: 14))
        g.stroke(ends, with: .color(Color(hex: 0xAFA9EC)), style: StrokeStyle(lineWidth: 3.4, lineCap: .round))
    }

    // LED eyes.
    switch color {
    case .red:   // panic: eyes on fire, flickering from the base
        for (flame, core, cx, offset) in [(Flames.left, Flames.leftCore, 20.5, 0.0), (Flames.right, Flames.rightCore, 39.5, Double.pi)] {
            let w = 2 * .pi * t / 0.42 + offset
            var gg = g
            gg.translateBy(x: cx, y: 34)
            gg.concatenate(CGAffineTransform(a: 1, b: 0, c: tan(5 * cos(w) * .pi / 180), d: 1.02 + 0.10 * sin(w), tx: 0, ty: 0))
            gg.translateBy(x: -cx, y: -34)
            gg.fill(flame, with: .color(Color(hex: 0xF0703C)))
            gg.translateBy(x: cx, y: 34)
            gg.scaleBy(x: 1, y: 0.975 + 0.175 * sin(2 * .pi * t / 0.3 + offset))
            gg.translateBy(x: -cx, y: -34)
            gg.fill(core, with: .color(led))
        }

    case .burnt:   // burnt out: X eyes, embers and smoke
        var eyes = Path()
        for (a, b) in [((15.5, 20.0), (25.5, 30.0)), ((25.5, 20.0), (15.5, 30.0)), ((34.5, 20.0), (44.5, 30.0)), ((44.5, 20.0), (34.5, 30.0))] {
            eyes.move(to: CGPoint(x: a.0, y: a.1)); eyes.addLine(to: CGPoint(x: b.0, y: b.1))
        }
        g.stroke(eyes, with: .color(led), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        for (x, y, offset) in [(9.0, 17.0, 0.0), (50.0, 35.0, Double.pi)] {
            let glow = 0.625 + 0.375 * sin(2 * .pi * t / 1.4 + offset)
            g.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: .color(Color(hex: 0xF0703C, alpha: glow)))
        }
        for (i, x0) in [24.0, 38.0, 31.0].enumerated() {
            let p = phase(t + Double(i) * 2.6 / 3, 2.6)
            let r = 3 * (0.6 + 0.8 * p)
            let c = CGPoint(x: x0 + 3 * p, y: 8 - 16 * p)
            g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(Color(hex: 0x8E8C86, alpha: 0.7 * sin(.pi * p))))
        }

    case .blue:   // focused, scanning from side to side
        let dx = CGFloat(3 * sin(2 * .pi * t / 1.3))
        if tired { tiredEyes(&g, led, dx: dx, t); break }
        g.fill(pill(14, 18.4, 13, 12.8, 5, dx: dx), with: .color(led))
        g.fill(pill(33, 18.4, 13, 12.8, 5, dx: dx), with: .color(led))

    case .backgroundBlue where peeking:   // sunk into the notch, peeking over the edge
        let dx = CGFloat(2.6 * sin(2 * .pi * t / 4))
        if tired { tiredEyes(&g, led, dx: dx, t); break }
        let p = phase(t, 5)
        let blink: CGFloat = (p > 0.90 && p < 0.94) ? 0.1 : 1
        g.fill(pill(14, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))
        g.fill(pill(33, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))

    case .backgroundBlue:   // panel open: whole head, scanning slowly and blinking
        let dx = CGFloat(3 * sin(2 * .pi * t / 4))
        if tired { tiredEyes(&g, led, dx: dx, t); break }
        let p = phase(t, 4)
        let blink: CGFloat = (p > 0.9 && p < 0.95) ? 0.12 : 1
        g.fill(pill(14, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))
        g.fill(pill(33, 18.4, 13, 12.8, 5, scaleY: blink, dx: dx), with: .color(led))

    case .yellow:   // eyes and exclamation mark alternating
        if Int(t / 0.8) % 2 == 0 {
            g.fill(pill(14, 16, 13, 17.4, 5.6), with: .color(led))
            g.fill(pill(33, 16, 13, 17.4, 5.6), with: .color(led))
        } else {
            g.fill(pill(26, 13, 8, 15.2, 4), with: .color(led))
            g.fill(Path(ellipseIn: CGRect(x: 26, y: 29.4, width: 8, height: 8)), with: .color(led))
        }

    case .green:   // smiling
        var arcs = Path()
        arcs.move(to: CGPoint(x: 15, y: 29)); arcs.addQuadCurve(to: CGPoint(x: 26, y: 29), control: CGPoint(x: 20.5, y: 18))
        arcs.move(to: CGPoint(x: 34, y: 29)); arcs.addQuadCurve(to: CGPoint(x: 45, y: 29), control: CGPoint(x: 39.5, y: 18))
        g.stroke(arcs, with: .color(led), style: StrokeStyle(lineWidth: 4.6, lineCap: .round))

    case .dimGreen:   // half-closed, blinking slowly
        let p = phase(t, 5)
        let blink: CGFloat = (p > 0.9 && p < 0.96) ? 0.12 : 1
        g.fill(pill(14, 21.6, 13, 8.6, 4, scaleY: blink), with: .color(led))
        g.fill(pill(33, 21.6, 13, 8.6, 4, scaleY: blink), with: .color(led))

    case .gray:   // sleeping: Z z lighting up in turn
        let wave = cos(2 * .pi * t / 2.4)
        var zg = Path()
        zg.addLines([CGPoint(x: 15, y: 17), CGPoint(x: 26, y: 17), CGPoint(x: 15, y: 32), CGPoint(x: 26, y: 32)])
        var zp = Path()
        zp.addLines([CGPoint(x: 35, y: 22), CGPoint(x: 44, y: 22), CGPoint(x: 35, y: 32), CGPoint(x: 44, y: 32)])
        g.stroke(zg, with: .color(led.opacity(0.675 + 0.325 * wave)),
                 style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        g.stroke(zp, with: .color(led.opacity(0.675 - 0.325 * wave)),
                 style: StrokeStyle(lineWidth: 3.6, lineCap: .round, lineJoin: .round))
    }

    // Reviving: four bits of soot fly off the shell and fade.
    if let p = revival {
        for (x, y, dx, dy) in [(12.0, 12.0, -1.0, -1.0), (48.0, 12.0, 1.0, -1.0), (10.0, 36.0, -1.0, 1.0), (50.0, 36.0, 1.0, 1.0)] {
            let c = CGPoint(x: x + dx * 12 * p, y: y + dy * 12 * p)
            g.fill(Path(ellipseIn: CGRect(x: c.x - 1.8, y: c.y - 1.8, width: 3.6, height: 3.6)),
                   with: .color(Color(hex: 0x5A4E46, alpha: 1 - p)))
        }
    }
}

func formatDuration(_ seconds: Double) -> String {
    let m = Int(seconds / 60)
    if m >= 60 { return "\(m / 60)h \(m % 60)min" }
    if m >= 1 { return "\(m) min" }
    return "\(Int(seconds)) s"
}

func shortTime(_ epoch: Double, _ format: String = "HH'h'mm") -> String {
    let f = DateFormatter()
    if isPortuguese {
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = format
    } else {
        // English with the region's conventions (12 or 24 hours).
        f.locale = Locale(identifier: "en_" + (Locale.current.region?.identifier ?? "US"))
        f.setLocalizedDateFormatFromTemplate(format.contains("EEE") ? "EEEjmm" : "jmm")
    }
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

struct DetailView: View {
    @ObservedObject var store: Store
    var onOpen: (Session) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LimitView(title: tr("Sessão de 5 horas", "5-hour session"), usageWindow: store.fiveHour, format: "HH:mm",
                       overflow: store.forecast, headroom: store.forecastHeadroom)
            LimitView(title: tr("Semana", "Week"), usageWindow: store.week, format: "EEE HH:mm")
            Divider()
            if store.sessions.isEmpty {
                Text(tr("Nenhuma sessão do Claude Code aberta.", "No Claude Code sessions open."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(store.sessions.prefix(5)) { s in
                    SessionView(s: s)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(s) }
                }
            }
            Divider()
            ScoreboardView(today: store.today, weekWaiting: store.weekWaiting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimitView: View {
    let title: String
    let usageWindow: UsageWindow?
    let format: String
    var overflow: Double? = nil
    var headroom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if let j = usageWindow {
                    Text("\(Int(j.pct.rounded()))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
            if let j = usageWindow {
                GeometryReader { geo in
                    let w = geo.size.width
                    let used = w * CGFloat(min(j.pct, 100) / 100)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        if overflow != nil {
                            Rectangle().fill(Color(hex: 0xEF9F27, alpha: 0.4))
                                .frame(width: max(0, w - used)).offset(x: used)
                        }
                        Capsule().fill(usageColor(j.pct)).frame(width: used)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                HStack {
                    Text(resetText(j)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if let e = overflow {
                        Text(tr("No ritmo atual, acaba às ", "At this pace, runs out at ") + shortTime(e))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0xFAC775))
                    } else if headroom {
                        Text(tr("No ritmo atual, dá folga", "At this pace, plenty left")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(tr("Aparece depois da primeira resposta numa sessão.", "Shows up after the first reply in a session."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    func resetText(_ j: UsageWindow) -> String {
        guard j.resetsAt > 0 else { return tr("Janela renovada", "Window reset") }
        return tr("Renova ", "Resets ") + shortTime(j.resetsAt, format)
    }
}

struct SessionView: View {
    let s: Session

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(waited >= Sounds.panicAfter ? Color(hex: 0xE24B4A)
                          : isHeavy ? Color(hex: 0xAFA9EC) : stateColor(s.state))
                .frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.project).font(.system(size: 12, weight: .semibold))
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                    if s.compactions > 0 {
                        Text(tr("compactada \(s.compactions)x", "compacted \(s.compactions)x"))
                            .font(.system(size: 10)).foregroundStyle(Color(hex: 0xCECBF6))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color(hex: 0xAFA9EC, alpha: 0.55), lineWidth: 1))
                            .fixedSize()   // the label gives way, not the tag
                    }
                    Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                if let r = s.summary, !r.isEmpty {
                    Text(r).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if s.state == .done && s.compactions > 0 {
                    Text(tr("Sugestão: limpe a sessão (/clear) antes do próximo pedido.",
                            "Tip: clear the session (/clear) before your next prompt."))
                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0xCECBF6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let c = s.ctx {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(tr("contexto", "context") + " \(Int(c.rounded()))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(c >= 80 ? Color(hex: 0xAFA9EC) : (c >= 70 ? Color.orange : Color.secondary))
                    ProgressView(value: min(c, 100), total: 100)
                        .tint(c >= 80 ? Color(hex: 0xAFA9EC) : usageColor(c)).frame(width: 60)
                }
            }
        }
    }

    /// Working (or running background tasks) above 80% of its context.
    var isHeavy: Bool { (s.state == .running || s.state == .background) && (s.ctx ?? 0) >= 80 }

    /// How long this session has been waiting for you, or 0 if it isn't waiting.
    var waited: Double { s.state == .awaiting ? Date().timeIntervalSince1970 - s.since : 0 }

    var label: String {
        let now = Date().timeIntervalSince1970
        let minutes = Int((now - s.since) / 60)
        let ago = minutes < 1 ? "agora" : "há \(minutes) min"
        let isJustNow = minutes < 1
        switch s.state {
        case .running:
            let silence = Int((now - s.updated) / 60)
            return silence >= 10
                ? tr("· trabalhando, sem sinal há \(silence) min", "· working, no signal for \(silence) min")
                : tr("· trabalhando, \(ago)", isJustNow ? "· working, just now" : "· working for \(minutes) min")
        case .background: return tr("· em segundo plano: ", "· in background: ") + (s.bg ?? tr("tarefas", "tasks"))
        case .awaiting:
            if waited >= Sounds.burnAfter {
                return tr("· queimou esperando você, há \(minutes) min", "· burnt out waiting for you, \(minutes) min")
            }
            return tr("· precisa de você, \(ago)", isJustNow ? "· needs you, just now" : "· needs you for \(minutes) min")
        case .done: return tr("· terminou, \(ago)", isJustNow ? "· finished just now" : "· finished \(minutes) min ago")
        case .idle: return tr("· parado, \(ago)", isJustNow ? "· idle, just now" : "· idle for \(minutes) min")
        }
    }
}

struct ScoreboardView: View {
    let today: Scoreboard
    let weekWaiting: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Hoje", "Today")).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(tr("7 dias: esperou você ", "7 days: waited for you ") + formatDuration(weekWaiting)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                metricTile(tr("Agente trabalhando", "Agent working"), formatDuration(today.working), nil)
                metricTile(tr("Esperando você", "Waiting for you"), formatDuration(today.waiting), Color(hex: 0xFAC775))
                metricTile(tr("Sua resposta média", "Your avg. reply"),
                        today.replyCount > 0 ? formatDuration(today.replyTime / Double(today.replyCount)) : tr("sem dados", "no data"), nil)
            }
            let total = today.working + today.waiting
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color(hex: 0x378ADD)).frame(width: geo.size.width * CGFloat(today.working / total))
                        Rectangle().fill(Color(hex: 0xEF9F27))
                    }
                }
                .frame(height: 5)
                .clipShape(Capsule())
            }
            if today.burnt > 0 {
                Text(tr("Psius queimados hoje: \(today.burnt)", "Psius burnt today: \(today.burnt)"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    func metricTile(_ label: String, _ valueText: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(valueText).font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(color ?? Color.primary)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - Entry point

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "hook": runHook(); exit(0)
case "statusline": runStatusLine(); exit(0)
case "install": runInstall(); exit(0)
case "uninstall": runUninstall(); exit(0)
case "setup", "configurar": setupWithoutWindow(); exit(0)
case "dmg-background", "fundo-dmg":
    MainActor.assumeIsolated { renderDMGBackground(args.count > 2 ? args[2] : ".") }
    exit(0)
case "icon", "icone":
    MainActor.assumeIsolated { renderIcon(args.count > 2 ? args[2] : "icon.png") }
    exit(0)
default: break
}

ensureDirs()
let lockFD = open(baseDir.appendingPathComponent("psiu.lock").path, O_CREAT | O_RDWR, 0o644)
if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print(tr("O Psiu já está aberto.", "Psiu is already open."))
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
