import Foundation

// MARK: - Statusline mode: context and plan limits

/// `Psiu statusline`: Claude Code sends context and plan limits; Psiu saves them and prints its status line.
public func runStatusLine(paths: PsiuPaths = .current) {
    paths.ensureDirectories()
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    let input = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
    let now = Date().timeIntervalSince1970

    let cw = input["context_window"] as? [String: Any]
    let ctx = num(cw?["used_percentage"])
    var parts: [String] = []

    if let rawID = input["session_id"] as? String {
        var m = SessionMetrics(updated: now, ctx: ctx)
        if let model = (input["model"] as? [String: Any])?["display_name"] as? String { m.model = model }
        if let dir = (input["workspace"] as? [String: Any])?["project_dir"] as? String {
            m.project = (dir as NSString).lastPathComponent
        }
        writeFile(m, to: paths.metrics(safeID(rawID)))
    }
    if let ctx { parts.append(tr("contexto", "context") + " \(Int(ctx.rounded()))%") }

    if let rl = input["rate_limits"] as? [String: Any] {
        var limits = readFile(LimitsFile.self, at: paths.limits) ?? LimitsFile()
        for (limitKey, label) in [("five_hour", "5h"), ("seven_day", tr("semana", "week"))] {
            guard let w = rl[limitKey] as? [String: Any], let p = num(w["used_percentage"]) else { continue }
            let window = LimitsFile.Window(pct: p, resets: num(w["resets_at"]) ?? 0)
            if limitKey == "five_hour" { limits.fiveHour = window } else { limits.sevenDay = window }
            parts.append("\(label) \(Int(p.rounded()))%")
        }
        limits.updated = now
        writeFile(limits, to: paths.limits)
    }

    // If you already had a status line, it keeps showing in place of Psiu's.
    if let prev = try? String(contentsOf: paths.previousStatusLine, encoding: .utf8)
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
