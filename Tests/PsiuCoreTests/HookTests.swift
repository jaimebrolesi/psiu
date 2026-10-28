import Foundation
import Testing
@testable import PsiuCore

@Suite("Hook events")
struct HookTests {
    /// Applies a series of events to one session, as Claude Code would send them, one second apart.
    func run(_ events: [[String: Any]], from start: SessionRecord? = nil) -> SessionRecord? {
        var rec = start
        for (i, e) in events.enumerated() {
            var e = e
            e["session_id"] = e["session_id"] ?? "s1"
            switch applyHookEvent(e, to: rec, now: 1000 + Double(i), terminal: noTerminal) {
            case .write(_, let r): rec = r
            case .remove: rec = nil
            case .ignore: break
            }
        }
        return rec
    }

    @Test func promptStartsWorking() throws {
        let r = try #require(run([["hook_event_name": "UserPromptSubmit", "cwd": "/tmp/demo", "prompt": "fix   the\n\ntests"]]))
        #expect(r.state == "running")
        #expect(r.project == "demo")
        #expect(r.summary == tr("Pedido: ", "Prompt: ") + "fix the tests")
        #expect(r.since == 1000)
        #expect(r.tty == "/dev/ttys001")
        #expect(r.bundle == "com.apple.Terminal")
    }

    @Test func sinceOnlyMovesWhenTheStateChanges() throws {
        let r = try #require(run([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            ["hook_event_name": "PreToolUse"],
            ["hook_event_name": "PostToolUse"],
        ]))
        #expect(r.state == "running")
        #expect(r.since == 1000)
        #expect(r.updated == 1002)
    }

    @Test func backgroundTaskPromptIsNotShownAsAPrompt() throws {
        let r = try #require(run([["hook_event_name": "UserPromptSubmit", "prompt": "<task-notification>done"]]))
        #expect(r.summary == tr("Retomou depois de uma tarefa em segundo plano.", "Resumed after a background task."))
    }

    @Test func permissionRequestWaitsForYou() throws {
        let r = try #require(run([["hook_event_name": "PermissionRequest", "tool_name": "Bash",
                                   "tool_input": ["command": "npm   install  x"]]]))
        #expect(r.state == "awaiting")
        #expect(r.summary == tr("Quer permissão para Bash: ", "Wants permission for Bash: ") + "npm install x")
        let other = try #require(run([["hook_event_name": "PermissionRequest", "tool_name": "Edit"]]))
        #expect(other.summary == tr("Quer permissão para usar Edit.", "Wants permission to use Edit."))
    }

    @Test func permissionNotificationKeepsTheFirstSummary() throws {
        let r = try #require(run([
            ["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission"],
            ["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "again"],
        ]))
        #expect(r.state == "awaiting")
        #expect(r.summary == "Claude needs your permission")
    }

    @Test func idleNotificationOnlyFixesAStuckWorkingSession() throws {
        let interrupted = try #require(run([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            ["hook_event_name": "Notification", "notification_type": "idle_prompt"],
        ]))
        #expect(interrupted.state == "idle")
        let finished = try #require(run([
            ["hook_event_name": "Stop"],
            ["hook_event_name": "Notification", "notification_type": "idle_prompt"],
        ]))
        #expect(finished.state == "done")
    }

    @Test func stopWithTasksStillRunningGoesToBackground() throws {
        let r = try #require(run([["hook_event_name": "Stop", "last_assistant_message": "Line 1\n\n## **Done** `ok`\n```",
                                   "background_tasks": [["type": "shell", "status": "running"], ["type": "shell", "status": "pending"],
                                                        ["type": "subagent"], ["type": "monitor", "status": "completed"]]]]))
        #expect(r.state == "background")
        #expect(r.bg == "2 shell, 1 subagent")
        #expect(r.summary == "Done ok")
    }

    @Test func stopWithoutTasksIsDone() throws {
        let r = try #require(run([
            ["hook_event_name": "Stop", "background_tasks": [["type": "shell"]]],
            ["hook_event_name": "Stop", "last_assistant_message": "the end", "background_tasks": []],
        ]))
        #expect(r.state == "done")
        #expect(r.bg == nil)
        #expect(r.summary == "the end")
    }

    @Test func compactionsCountUntilClear() throws {
        let compacted = try #require(run([
            ["hook_event_name": "PreCompact", "trigger": "auto"],
            ["hook_event_name": "SessionStart", "source": "compact"],
            ["hook_event_name": "PreCompact", "trigger": "manual"],
        ]))
        #expect(compacted.compactions == 2)
        let cleared = run([["hook_event_name": "SessionStart", "source": "clear"]], from: compacted)
        #expect(cleared?.compactions == 0)
        #expect(cleared?.state == "idle")
    }

    @Test func compactionKeepsTheStateAndBackgroundTasks() throws {
        let r = try #require(run([
            ["hook_event_name": "UserPromptSubmit", "prompt": "x"],
            ["hook_event_name": "Stop", "background_tasks": [["type": "shell"], ["type": "shell"]]],
            ["hook_event_name": "PreCompact", "trigger": "auto"],
            ["hook_event_name": "SessionStart", "source": "compact"],
        ]))
        #expect(r.state == "background")
        #expect(r.since == 1001)
        #expect(r.bg == "2 shell")
        #expect(r.backgroundWork == true)
        #expect(r.compactions == 1)
        let fresh = try #require(run([["hook_event_name": "SessionStart", "source": "compact"]]))
        #expect(fresh.state == "idle")
    }

    @Test func sessionEndRemovesAndBadInputIsIgnored() {
        #expect(applyHookEvent(["session_id": "s1", "hook_event_name": "SessionEnd"], to: nil, now: 0, terminal: noTerminal) == .remove(id: "s1"))
        #expect(applyHookEvent(["hook_event_name": "Stop"], to: nil, now: 0, terminal: noTerminal) == .ignore)
        #expect(applyHookEvent(["session_id": "../", "hook_event_name": "Stop"], to: nil, now: 0, terminal: noTerminal) == .ignore)
    }

    @Test func sessionIDsBecomeSafeFileNames() {
        guard case .write(let id, _) = applyHookEvent(["session_id": "../../x y_1-2", "hook_event_name": "SessionStart"],
                                                      to: nil, now: 0, terminal: noTerminal) else {
            Issue.record("expected a write"); return
        }
        #expect(id == "xy_1-2")
    }

    @Test func theTerminalIsOnlyLookedUpOnce() {
        var lookups = 0
        let terminal = { lookups += 1; return TerminalInfo(bundle: nil, termprog: nil, tty: "") }
        var rec: SessionRecord?
        for event in ["SessionStart", "UserPromptSubmit", "Stop"] {
            if case .write(_, let r) = applyHookEvent(["session_id": "s", "hook_event_name": event], to: rec, now: 0, terminal: terminal) { rec = r }
        }
        #expect(lookups == 1)
    }

    @Test func snippetsLoseTheirMarkup() {
        #expect(lastSnippet("First\n\n- **Bold** `code`\n---\n```") == "Bold code")
        #expect(condense("a\n\n  b\tc", 10) == "a b c")
        #expect(condense(String(repeating: "x", count: 12), 10) == String(repeating: "x", count: 10) + "…")
    }
}

@Suite("Hooks running at the same time")
struct ConcurrentHookTests {
    @Test func parallelHooksDontLoseEachOthersWrites() throws {
        let home = TemporaryHome(), p = home.paths
        let event = Data(#"{"session_id":"s1","hook_event_name":"PreCompact","trigger":"auto"}"#.utf8)
        DispatchQueue.concurrentPerform(iterations: 50) { _ in
            handleHookEvent(event, paths: p, now: 1000, terminal: noTerminal)
        }
        #expect(readFile(SessionRecord.self, at: p.session("s1"))?.compactions == 50)
    }
}

@Suite("Claude Code's process")
struct ClaudeProcessTests {
    @Test func everyEventRecordsTheProcessAResumedSessionRunsInANewOne() throws {
        let first = ClaudeProcess(pid: 100, start: 5), resumed = ClaudeProcess(pid: 200, start: 9)
        guard case .write(_, let r1) = applyHookEvent(["session_id": "s", "hook_event_name": "SessionStart"], to: nil, now: 0,
                                                      terminal: noTerminal, process: first),
              case .write(_, let r2) = applyHookEvent(["session_id": "s", "hook_event_name": "UserPromptSubmit", "prompt": "x"], to: r1, now: 1,
                                                      terminal: noTerminal, process: resumed) else {
            Issue.record("expected writes"); return
        }
        #expect(r1.pid == 100 && r1.pidStart == 5)
        #expect(r2.pid == 200 && r2.pidStart == 9)
    }

    @Test func aKilledProcessIsNoLongerRunning() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["300"]
        try sleeper.run()
        let info = try #require(ClaudeProcess.bsdInfo(sleeper.processIdentifier))
        let process = ClaudeProcess(pid: sleeper.processIdentifier, start: Double(info.pbi_start_tvsec))
        #expect(process.isRunning)
        #expect(!ClaudeProcess(pid: process.pid, start: process.start - 60).isRunning)   // same pid, another process

        // A session of that process shows up; once it is killed (no SessionEnd), the session goes away.
        let home = TemporaryHome(), p = home.paths
        let now = Date().timeIntervalSince1970
        writeFile({ var r = SessionRecord(); r.state = "running"; r.since = now; r.updated = now
                    r.pid = process.pid; r.pidStart = process.start; return r }(), to: p.session("s"))
        let repo = SessionRepository(paths: p)
        #expect(repo.sessions(now: now).map(\.id) == ["s"])
        kill(sleeper.processIdentifier, SIGKILL)
        sleeper.waitUntilExit()
        #expect(!process.isRunning)
        #expect(repo.sessions(now: now).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: p.session("s").path))
    }

    @Test func theHookFindsTheProcessAboveIt() throws {
        let process = try #require(ClaudeProcess.current())
        #expect(process.isRunning)
    }
}

/// Sequences recorded from a real Claude Code session (2.1.310): two subagents in parallel, A asks for permission
/// while B keeps reading files, and the main agent ends its turn with both in the background.
@Suite("Permission while other agents work")
struct WaitingAgentsTests {
    /// The state after each event.
    func states(_ events: [[String: Any]]) -> [String?] {
        var rec: SessionRecord?
        return events.enumerated().map { i, e in
            var e = e
            e["session_id"] = "s1"
            if case .write(_, let r) = applyHookEvent(e, to: rec, now: 1000 + Double(i), terminal: noTerminal) { rec = r }
            return rec?.state
        }
    }

    let start: [[String: Any]] = [
        ["hook_event_name": "UserPromptSubmit", "prompt": "launch two subagents"],
        ["hook_event_name": "PreToolUse", "tool_name": "Agent"],
        ["hook_event_name": "PostToolUse", "tool_name": "Agent"],
        ["hook_event_name": "PreToolUse", "tool_name": "Bash", "agent_id": "A", "tool_input": ["command": "touch probe-a.txt"]],
        ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "agent_id": "A", "tool_input": ["command": "touch probe-a.txt"]],
    ]
    let meanwhile: [[String: Any]] = [
        ["hook_event_name": "Stop", "last_assistant_message": "Both launched.",
         "background_tasks": [["type": "subagent", "status": "running"], ["type": "subagent", "status": "running"]]],
        ["hook_event_name": "PreToolUse", "tool_name": "Read", "agent_id": "B"],
        ["hook_event_name": "PostToolUse", "tool_name": "Read", "agent_id": "B"],
        ["hook_event_name": "SubagentStop", "agent_id": "internal"],
        ["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission"],
        ["hook_event_name": "PreToolUse", "tool_name": "Read", "agent_id": "B"],
        ["hook_event_name": "PostToolUse", "tool_name": "Read", "agent_id": "B"],
        ["hook_event_name": "SubagentStop", "agent_id": "B"],
        ["hook_event_name": "UserPromptSubmit", "prompt": "<task-notification>B finished"],
        ["hook_event_name": "Stop", "background_tasks": [["type": "subagent", "status": "running"]]],
        ["hook_event_name": "PreToolUse", "tool_name": "Bash", "agent_id": "internal"],
    ]

    @Test func staysYellowWhileOtherAgentsWorkThenGoesOnWhenYouApprove() throws {
        let after: [[String: Any]] = [
            ["hook_event_name": "PostToolUse", "tool_name": "Bash", "agent_id": "A"],
            ["hook_event_name": "SubagentStop", "agent_id": "A"],
            ["hook_event_name": "UserPromptSubmit", "prompt": "<task-notification>A finished"],
            ["hook_event_name": "Stop", "last_assistant_message": "Done.", "background_tasks": []],
        ]
        let s = states(start + meanwhile + after)
        #expect(s[start.count - 1] == "awaiting")
        #expect(s[start.count..<(start.count + meanwhile.count)].allSatisfy { $0 == "awaiting" })
        #expect(Array(s.suffix(after.count)) == ["running", "running", "running", "done"])
    }

    @Test func theRequestStaysOnScreenAndTheWaitKeepsItsStart() throws {
        var rec: SessionRecord?
        for (i, e) in (start + meanwhile).enumerated() {
            var e = e
            e["session_id"] = "s1"
            if case .write(_, let r) = applyHookEvent(e, to: rec, now: 1000 + Double(i), terminal: noTerminal) { rec = r }
        }
        let r = try #require(rec)
        #expect(r.summary == tr("Quer permissão para Bash: ", "Wants permission for Bash: ") + "touch probe-a.txt")
        #expect(r.since == 1000 + Double(start.count - 1))   // panic and burn count from the request
        #expect(r.waiting == ["A"])
        #expect(r.bg == "1 subagent")
    }

    @Test func aDeniedSubagentEndsAndTheSessionGoesOn() throws {
        let after: [[String: Any]] = [
            ["hook_event_name": "SubagentStop", "agent_id": "A"],
            ["hook_event_name": "UserPromptSubmit", "prompt": "<task-notification>A was denied"],
            ["hook_event_name": "Stop", "background_tasks": []],
        ]
        #expect(Array(states(start + meanwhile + after).suffix(after.count)) == ["running", "running", "done"])
    }

    @Test func theMainAgentsPermissionWorksAsBefore() throws {
        #expect(states([
            ["hook_event_name": "UserPromptSubmit", "prompt": "touch and read"],
            ["hook_event_name": "PreToolUse", "tool_name": "Bash"],
            ["hook_event_name": "PermissionRequest", "tool_name": "Bash"],
            ["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission"],
            ["hook_event_name": "PostToolUse", "tool_name": "Bash"],
            ["hook_event_name": "PreToolUse", "tool_name": "Read"],
            ["hook_event_name": "PostToolUse", "tool_name": "Read"],
            ["hook_event_name": "Stop", "background_tasks": []],
        ]) == ["running", "running", "awaiting", "awaiting", "running", "running", "running", "done"])
    }

    @Test func aFailedToolOrANotificationAloneAlsoWork() throws {
        #expect(states([
            ["hook_event_name": "Notification", "notification_type": "elicitation_dialog", "message": "Pick one"],
            ["hook_event_name": "PreToolUse", "tool_name": "Read", "agent_id": "B"],
            ["hook_event_name": "PostToolUseFailure", "tool_name": "Read"],
        ]) == ["awaiting", "awaiting", "running"])
    }

    @Test func typingAPromptClosesEveryDialog() throws {
        let s = states(start + [["hook_event_name": "UserPromptSubmit", "prompt": "never mind"]])
        #expect(s.last == "running")
    }
}

/// Denying the main agent's permission with Esc fires no hook event (Claude Code 2.1.310); only the transcript,
/// untouched while the dialog is open, is written about a second later.
@Suite("Permission you denied in the main agent")
struct DeniedMainAgentTests {
    let home = TemporaryHome()
    var transcript: URL { home.paths.home.appendingPathComponent("transcript.jsonl") }

    /// The session as the app shows it, with the transcript last written at `written`.
    func shown(_ events: [[String: Any]], transcriptWritten written: Double?) throws -> Session? {
        var rec: SessionRecord?
        for (i, e) in events.enumerated() {
            var e = e
            e["session_id"] = "s1"
            e["transcript_path"] = transcript.path
            if case .write(_, let r) = applyHookEvent(e, to: rec, now: 1000 + Double(i), terminal: noTerminal) { rec = r }
        }
        writeFile(try #require(rec), to: home.paths.session("s1"))
        if let written {
            try Data("{}\n".utf8).write(to: transcript)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: written)], ofItemAtPath: transcript.path)
        }
        return SessionRepository(paths: home.paths).sessions(now: 2000).first
    }

    let mainRequest: [[String: Any]] = [
        ["hook_event_name": "UserPromptSubmit", "prompt": "touch a file"],
        ["hook_event_name": "PreToolUse", "tool_name": "Bash"],
        ["hook_event_name": "PermissionRequest", "tool_name": "Bash"],   // at 1002
        ["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "Claude needs your permission"],
    ]

    @Test func theHookRecordsTheTranscriptsPath() throws {
        #expect(try shown(mainRequest, transcriptWritten: nil) != nil)
        let raw = try #require(readFile(SessionRecord.self, at: home.paths.session("s1")))
        #expect(raw.transcript == transcript.path)
    }

    @Test func theTranscriptWrittenAfterTheRequestMeansYouDenied() throws {
        let s = try #require(try shown(mainRequest, transcriptWritten: 1033))
        #expect(s.state == .idle)
        #expect(s.since == 1033)
    }

    @Test func anUntouchedTranscriptStillWaitsForYou() throws {
        #expect(try shown(mainRequest, transcriptWritten: nil)?.state == .awaiting)       // no transcript saved
        #expect(try shown(mainRequest, transcriptWritten: 990)?.state == .awaiting)
        #expect(try shown(mainRequest, transcriptWritten: 1002.2)?.state == .awaiting)   // the flush right after the request
    }

    @Test func aSubagentsRequestIgnoresTheTranscript() throws {
        let subagent: [[String: Any]] = [
            ["hook_event_name": "PreToolUse", "tool_name": "Bash", "agent_id": "A"],
            ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "agent_id": "A"],
        ]
        #expect(try shown(subagent, transcriptWritten: 1500)?.state == .awaiting)
    }

    /// A shell or subagent ending in the background writes the transcript while the dialog is still open.
    @Test func backgroundWorkKeepsItWaiting() throws {
        let launchesASubagent: [[String: Any]] = [
            ["hook_event_name": "UserPromptSubmit", "prompt": "launch a subagent, then touch a file"],
            ["hook_event_name": "PreToolUse", "tool_name": "Agent"],
            ["hook_event_name": "PostToolUse", "tool_name": "Agent"],
            ["hook_event_name": "PreToolUse", "tool_name": "Bash"],
            ["hook_event_name": "PermissionRequest", "tool_name": "Bash"],
            ["hook_event_name": "PreToolUse", "tool_name": "Read", "agent_id": "B"],
            ["hook_event_name": "PostToolUse", "tool_name": "Read", "agent_id": "B"],
        ]
        #expect(try shown(launchesASubagent, transcriptWritten: 1100)?.state == .awaiting)

        let shellStillRunning: [[String: Any]] = [
            ["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": ["command": "sleep 25", "run_in_background": true]],
            ["hook_event_name": "PostToolUse", "tool_name": "Bash"],
            ["hook_event_name": "Stop", "background_tasks": [["type": "shell", "status": "running"]]],
        ]
        #expect(try shown(shellStillRunning + mainRequest, transcriptWritten: 1100)?.state == .awaiting)
    }

    @Test func onceNothingIsLeftInTheBackgroundTheRuleIsBack() throws {
        let finished: [[String: Any]] = [
            ["hook_event_name": "PreToolUse", "tool_name": "Agent"],
            ["hook_event_name": "Stop", "background_tasks": []],
            ["hook_event_name": "SubagentStop", "agent_id": "internal"],
        ]
        #expect(try shown(finished + mainRequest, transcriptWritten: 1100)?.state == .idle)
    }
}
