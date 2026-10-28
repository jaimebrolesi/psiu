import Foundation

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

/// Where a session runs, learned on its first event.
public struct TerminalInfo: Sendable {
    public var bundle: String?
    public var termprog: String?
    public var tty: String

    public init(bundle: String?, termprog: String?, tty: String) { self.bundle = bundle; self.termprog = termprog; self.tty = tty }

    /// This process's terminal: the app that runs Claude Code and its tty.
    public static func current() -> TerminalInfo {
        let env = ProcessInfo.processInfo.environment
        return TerminalInfo(bundle: env["__CFBundleIdentifier"], termprog: env["TERM_PROGRAM"], tty: currentTTY() ?? "")
    }
}

/// What a hook event does to its session's file.
public enum HookOutcome: Equatable, Sendable {
    case ignore
    case remove(id: String)
    case write(id: String, record: SessionRecord)
}

/// What a Claude Code hook event does to the session's record. No files and no clock, so it can be tested.
public func applyHookEvent(_ input: [String: Any], to existing: SessionRecord?, now: Double,
                           terminal: () -> TerminalInfo, process: ClaudeProcess? = nil) -> HookOutcome {
    guard let rawID = input["session_id"] as? String else { return .ignore }
    let sid = safeID(rawID)
    guard !sid.isEmpty else { return .ignore }
    let event = input["hook_event_name"] as? String ?? ""
    if event == "SessionEnd" { return .remove(id: sid) }

    var rec = existing ?? SessionRecord()
    if rec.project == nil, let cwd = input["cwd"] as? String, !cwd.isEmpty {
        rec.project = (cwd as NSString).lastPathComponent
    }
    if rec.tty == nil {
        let t = terminal()
        rec.bundle = t.bundle
        rec.termprog = t.termprog
        rec.tty = t.tty
    }
    // On every event: a resumed session runs in a new process.
    if let process {
        rec.pid = process.pid
        rec.pidStart = process.start
    }
    if let t = input["transcript_path"] as? String, !t.isEmpty { rec.transcript = t }
    let previousState = rec.state
    // The agents with a permission dialog open: "" is the main agent, others are subagents (agent_id). While one
    // waits, the others keep working and the main agent may even stop, but the session still needs you.
    let agent = input["agent_id"] as? String ?? ""
    var waiting = rec.waiting ?? []
    // Subagents run in the background, and so does a shell started with run_in_background; Stop says what's left.
    let toolInput = input["tool_input"] as? [String: Any]
    if event == "PreToolUse", agent.isEmpty, ["Agent", "Task"].contains(input["tool_name"] as? String ?? "")
        || toolInput?["run_in_background"] as? Bool == true {
        rec.backgroundWork = true
    }

    var newState: String?
    switch event {
    case "SessionStart":
        // A compaction (even one Claude Code does on its own while idle) goes on with the same session: its
        // state, dialogs and background tasks stay as they were.
        if input["source"] as? String == "compact", rec.state != nil { break }
        newState = "idle"
        waiting = []
        rec.backgroundWork = nil
        // /clear starts the session over; the SessionStart after a compaction is not counted again.
        if input["source"] as? String == "clear" { rec.compactions = 0 }
    case "PreCompact":
        rec.compactions = (rec.compactions ?? 0) + 1
    case "UserPromptSubmit":
        let prompt = input["prompt"] as? String ?? ""
        let resumed = prompt.hasPrefix("<")   // a background task finished, not you typing
        if !resumed { waiting = [] }          // you typed: no dialog is open anymore
        if waiting.isEmpty {
            newState = "running"
            rec.summary = resumed
                ? tr("Retomou depois de uma tarefa em segundo plano.", "Resumed after a background task.")
                : tr("Pedido: ", "Prompt: ") + condense(prompt, 140)
        }
    case "PreToolUse", "PostToolUse", "PostToolUseFailure":
        // The waiting agent moving on means its permission was answered.
        waiting.removeAll { $0 == agent }
        if waiting.isEmpty { newState = "running" }
    case "SubagentStop":
        // A subagent whose permission you denied just ends.
        if waiting.contains(agent) {
            waiting.removeAll { $0 == agent }
            if waiting.isEmpty { newState = "running" }
        }
    case "PermissionRequest":
        newState = "awaiting"
        if !waiting.contains(agent) { waiting.append(agent) }
        let tool = input["tool_name"] as? String ?? tr("uma ferramenta", "a tool")
        if let cmd = toolInput?["command"] as? String {
            rec.summary = tr("Quer permissão para \(tool): ", "Wants permission for \(tool): ") + condense(cmd, 90)
        } else {
            rec.summary = tr("Quer permissão para usar \(tool).", "Wants permission to use \(tool).")
        }
    case "Notification":
        let kind = input["notification_type"] as? String ?? ""
        let msg = (input["message"] as? String ?? "").lowercased()
        if kind == "permission_prompt" || kind == "elicitation_dialog" || msg.contains("permission") {
            newState = "awaiting"
            // It doesn't say which agent asks; PermissionRequest usually came first and did.
            if waiting.isEmpty { waiting = [agent] }
            if previousState != "awaiting", let m = input["message"] as? String { rec.summary = condense(m, 140) }
        } else if kind == "idle_prompt", rec.state == "running" {
            // You interrupted with Esc: Stop doesn't fire, so idle fixes the stuck blue.
            newState = "idle"
        }
    case "Stop":
        // The main agent stopped; a subagent may still be waiting for you, and its request stays on screen.
        waiting.removeAll { $0 == "" }
        if waiting.isEmpty, let m = input["last_assistant_message"] as? String, !m.isEmpty { rec.summary = lastSnippet(m) }
        // Stop lists the tasks still running (shells, monitors, subagents).
        let tasks = (input["background_tasks"] as? [[String: Any]] ?? []).filter {
            let st = $0["status"] as? String ?? "running"
            return st == "running" || st == "pending"
        }
        rec.backgroundWork = tasks.isEmpty ? nil : true
        if tasks.isEmpty {
            if waiting.isEmpty { newState = "done" }
            rec.bg = nil
        } else {
            if waiting.isEmpty { newState = "background" }
            var order: [String] = []
            var counts: [String: Int] = [:]
            for t in tasks {
                let kind = t["type"] as? String ?? tr("tarefa", "task")
                if counts[kind] == nil { order.append(kind) }
                counts[kind, default: 0] += 1
            }
            rec.bg = order.map { "\(counts[$0] ?? 0) \($0)" }.joined(separator: ", ")
        }
    default:
        break
    }

    if let s = newState {
        if rec.state != s { rec.since = now }
        rec.state = s
    }
    rec.waiting = waiting.isEmpty ? nil : waiting
    rec.updated = now
    return .write(id: sid, record: rec)
}

/// `Psiu hook`: Claude Code sends each event on standard input.
public func runHook(paths: PsiuPaths = .current) {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    handleHookEvent(data, paths: paths, now: Date().timeIntervalSince1970, terminal: TerminalInfo.current,
                    process: ClaudeProcess.current())
    // Nothing on stdout: on UserPromptSubmit, anything printed here would go into Claude's context.
}

/// Applies one event to its session's file. Claude Code runs the hooks of parallel tool calls at the same time,
/// so reading and writing happen under a lock: otherwise one hook could overwrite what another just wrote.
public func handleHookEvent(_ data: Data, paths: PsiuPaths, now: Double, terminal: () -> TerminalInfo,
                            process: ClaudeProcess? = nil) {
    paths.ensureDirectories()
    guard let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    let lock = open(paths.hooksLock.path, O_CREAT | O_RDWR, 0o644)
    if lock >= 0 { flock(lock, LOCK_EX) }
    defer { if lock >= 0 { close(lock) } }   // closing releases the lock
    let id = (input["session_id"] as? String).map(safeID) ?? ""
    let existing = id.isEmpty ? nil : readFile(SessionRecord.self, at: paths.session(id))
    switch applyHookEvent(input, to: existing, now: now, terminal: terminal, process: process) {
    case .ignore:
        break
    case .remove(let id):
        try? FileManager.default.removeItem(at: paths.session(id))
        try? FileManager.default.removeItem(at: paths.metrics(id))
    case .write(let id, let record):
        writeFile(record, to: paths.session(id))
    }
}
