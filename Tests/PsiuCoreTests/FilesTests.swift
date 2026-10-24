import Foundation
import Testing
@testable import PsiuCore

@Suite("Files in ~/.psiu")
struct RepositoryTests {
    func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

    @Test func readsSessionsWithTheirMetricsNewestFirst() throws {
        let home = TemporaryHome(), p = home.paths
        let now = 1_800_000_000.0
        try write(#"{"state":"running","since":\#(now - 60),"updated":\#(now),"project":"api","resumo":"Prompt: x","compactacoes":2}"#, to: p.session("a"))
        try write(#"{"state":"awaiting","since":\#(now - 10),"updated":\#(now)}"#, to: p.session("b"))
        try write(#"{"ctx":84,"model":"Opus","project":"web"}"#, to: p.metrics("b"))
        let list = SessionRepository(paths: p).sessions(now: now)
        #expect(list.map(\.id) == ["b", "a"])
        #expect(list[0].project == "web")   // no project in the session file: the status line's
        #expect(list[0].ctx == 84)
        #expect(list[1].summary == "Prompt: x")
        #expect(list[1].compactions == 2)
        #expect(list[1].state == .running)
    }

    @Test func seesARewriteOfTheSameFile() throws {
        let home = TemporaryHome(), p = home.paths
        let repo = SessionRepository(paths: p)
        try write(#"{"state":"running","since":1,"updated":100}"#, to: p.session("a"))
        #expect(repo.sessions(now: 100).first?.state == .running)
        repo.endPass()
        try write(#"{"state":"done","since":2,"updated":100}"#, to: p.session("a"))
        #expect(repo.sessions(now: 100).first?.state == .done)
    }

    @Test func deletesSessionsAbandonedForTwelveHours() throws {
        let home = TemporaryHome(), p = home.paths
        let now = 1_800_000_000.0
        try write(#"{"state":"running","since":1,"updated":\#(now - 12 * 3600 - 1)}"#, to: p.session("old"))
        try write(#"{"ctx":10}"#, to: p.metrics("old"))
        try write(#"{"state":"idle","since":1,"updated":\#(now - 3600)}"#, to: p.session("recent"))
        #expect(SessionRepository(paths: p).sessions(now: now).map(\.id) == ["recent"])
        #expect(!FileManager.default.fileExists(atPath: p.session("old").path))
        #expect(!FileManager.default.fileExists(atPath: p.metrics("old").path))
    }

    @Test func toleratesBrokenAndOddFiles() throws {
        let home = TemporaryHome(), p = home.paths
        try write("not json", to: p.session("broken"))
        try write(#"{"state":"flying","since":"yesterday","updated":5}"#, to: p.session("odd"))
        let list = SessionRepository(paths: p).sessions(now: 5)
        #expect(list.map(\.id) == ["odd"])
        #expect(list[0].state == .idle)
        #expect(list[0].since == 5)
        #expect(list[0].project == tr("sessão", "session"))
    }

    @Test func readsThePlanLimits() throws {
        let home = TemporaryHome(), p = home.paths
        try write(#"{"five_hour":{"pct":30,"resets":9999999999},"seven_day":{"pct":12},"updated":7}"#, to: p.limits)
        let l = try #require(SessionRepository(paths: p).limits())
        #expect(l.fiveHour == .init(pct: 30, resets: 9_999_999_999))
        #expect(l.sevenDay?.pct == 12)
        #expect(l.updated == 7)
    }

    @Test func prefsKeepTheirPortugueseNames() throws {
        let home = TemporaryHome(), p = home.paths
        writeFile(Prefs(muted: true, hiddenScreens: ["Studio Display"]), to: p.prefs)
        let raw = json(p.prefs)
        #expect(raw["mudo"] as? Bool == true)
        #expect(raw["ocultas"] as? [String] == ["Studio Display"])
        #expect(readFile(Prefs.self, at: p.prefs) == Prefs(muted: true, hiddenScreens: ["Studio Display"]))
    }
}

@Suite("Install, uninstall and Farol")
struct InstallerTests {
    func hookCommands(_ settings: [String: Any], _ event: String) -> [String] {
        ((settings["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func installsOnceKeepsOtherToolsAndUninstallsCleanly() throws {
        let home = TemporaryHome(), p = home.paths
        try FileManager.default.createDirectory(at: p.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = #"{"theme":"dark","statusLine":{"type":"command","command":"echo mine"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/usr/bin/true other"}]}],"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"\"/opt/x/.farol/bin/Farol\" hook"}]}]}}"#
        try Data(original.utf8).write(to: p.settings)

        #expect(!isPsiuConnected(paths: p, executable: psiuExecutable))
        runInstall(paths: p, executable: psiuExecutable)
        runInstall(paths: p, executable: psiuExecutable)
        let s = json(p.settings)
        for (event, _) in hookEvents {
            #expect(hookCommands(s, event).filter { $0.contains(psiuExecutable) } == ["\"\(psiuExecutable)\" hook"], "\(event)")
        }
        #expect(hookCommands(s, "Stop").contains("/usr/bin/true other"))
        #expect(!hookCommands(s, "PreToolUse").contains { $0.contains(".farol") })   // Farol's hook was swapped
        #expect(s["theme"] as? String == "dark")
        #expect(isPsiuConnected(paths: p, executable: psiuExecutable))
        #expect(!isMissingHooks(paths: p, executable: psiuExecutable))
        #expect(try String(contentsOf: p.previousStatusLine, encoding: .utf8) == "echo mine")

        runUninstall(paths: p)
        let after = json(p.settings)
        #expect(after["theme"] as? String == "dark")
        #expect((after["statusLine"] as? [String: Any])?["command"] as? String == "echo mine")
        #expect(hookCommands(after, "Stop") == ["/usr/bin/true other"])
        #expect(hookCommands(after, "PreToolUse").isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: p.settings.deletingLastPathComponent().path)
            .filter { $0.hasPrefix("settings.json.psiu-backup-") }
        #expect(backups.count == 1)
    }

    @Test func noticesHooksMissingFromAnOlderInstall() throws {
        let home = TemporaryHome(), p = home.paths
        runInstall(paths: p, executable: psiuExecutable)
        var s = json(p.settings)
        var hooks = s["hooks"] as? [String: Any] ?? [:]
        hooks["PreCompact"] = nil
        s["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: s).write(to: p.settings)
        #expect(isMissingHooks(paths: p, executable: psiuExecutable))
    }

    @Test func migratesFromFarol() throws {
        let home = TemporaryHome(), p = home.paths, fm = FileManager.default
        try fm.removeItem(at: p.base)
        try fm.createDirectory(at: p.farol.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data(#"{"dias":{}}"#.utf8).write(to: p.farol.appendingPathComponent("placar.json"))
        try Data(#"{"mudo":true}"#.utf8).write(to: p.farol.appendingPathComponent("prefs.json"))
        try Data("echo old".utf8).write(to: p.farol.appendingPathComponent("statusline-anterior.txt"))
        try fm.createDirectory(at: p.farolAgent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: p.farolAgent)
        #expect(hasFarol(paths: p))

        var stopped = false
        migrateFromFarol(paths: p, executable: psiuExecutable, stopService: { stopped = true })
        #expect(stopped)
        #expect(!fm.fileExists(atPath: p.farolAgent.path))
        #expect(readFile(Prefs.self, at: p.prefs)?.muted == true)
        #expect(fm.fileExists(atPath: p.scoreboard.path))
        #expect(try String(contentsOf: p.previousStatusLine, encoding: .utf8) == "echo old")
        // Sessions opened before the switch still call ~/.farol/bin/Farol: it now points to Psiu.
        #expect(try fm.destinationOfSymbolicLink(atPath: p.farol.appendingPathComponent("bin/Farol").path) == psiuExecutable)
        #expect(try fm.contentsOfDirectory(atPath: p.farol.path) == ["bin"])
    }

    @Test func migrationKeepsWhatPsiuAlreadyHas() throws {
        let home = TemporaryHome(), p = home.paths, fm = FileManager.default
        try fm.createDirectory(at: p.farol, withIntermediateDirectories: true)
        try Data(#"{"mudo":true}"#.utf8).write(to: p.farol.appendingPathComponent("prefs.json"))
        writeFile(Prefs(muted: false), to: p.prefs)
        migrateFromFarol(paths: p, executable: psiuExecutable, stopService: {})
        #expect(readFile(Prefs.self, at: p.prefs)?.muted == false)
    }
}
