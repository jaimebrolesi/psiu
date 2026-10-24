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
