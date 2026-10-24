import Foundation

// MARK: - Statusline mode: context and plan limits

/// `Psiu statusline`: Claude Code sends context and plan limits; Psiu saves them and prints its status line.
public func runStatusLine(paths: PsiuPaths = .current) {
    let raw = FileHandle.standardInput.readDataToEndOfFile()
    FileHandle.standardOutput.write(statusLine(input: raw, paths: paths, now: Date().timeIntervalSince1970))
}

/// Saves what the status line brings and returns the text to show. No stdin or stdout, so it can be tested.
public func statusLine(input raw: Data, paths: PsiuPaths, now: Double, previousTimeout: TimeInterval = 2) -> Data {
    paths.ensureDirectories()
    let input = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]

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
        .trimmingCharacters(in: .whitespacesAndNewlines), !prev.isEmpty,
       let out = runPreviousStatusLine(prev, input: raw, timeout: previousTimeout) {
        return out
    }
    return Data((parts.joined(separator: " | ") + "\n").utf8)
}

/// Runs the status line you had before Psiu, with the same input. Nil if it doesn't start or takes longer than
/// `timeout`: Psiu then shows its own line instead of holding up the terminal's.
func runPreviousStatusLine(_ command: String, input: Data, timeout: TimeInterval) -> Data? {
    final class Output: @unchecked Sendable { var data = Data() }   // written before the semaphore, read after
    signal(SIGPIPE, SIG_IGN)   // a status line that never reads its input must not kill Psiu
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe
    p.standardOutput = outPipe
    guard (try? p.run()) != nil else { return nil }
    let output = Output(), finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        try? inPipe.fileHandleForWriting.write(contentsOf: input)
        try? inPipe.fileHandleForWriting.close()
    }
    DispatchQueue.global().async {
        output.data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        finished.signal()
    }
    guard finished.wait(timeout: .now() + timeout) == .success else {
        p.terminate()
        Log.core.error("The previous status line took longer than \(timeout, privacy: .public) s")
        return nil
    }
    return output.data
}
