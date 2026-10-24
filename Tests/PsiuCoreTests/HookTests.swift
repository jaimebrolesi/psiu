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
