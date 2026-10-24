import Foundation
import Testing
@testable import PsiuCore

@Suite("Status line")
struct StatusLineTests {
    let input = Data(#"{"session_id":"s1","context_window":{"used_percentage":42},"model":{"display_name":"Opus"},"workspace":{"project_dir":"/tmp/api"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":9999999999},"seven_day":{"used_percentage":12}}}"#.utf8)

    func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    @Test func savesContextAndLimitsAndPrintsItsOwnLine() throws {
        let home = TemporaryHome(), p = home.paths
        let out = statusLine(input: input, paths: p, now: 50)
        #expect(text(out) == tr("contexto", "context") + " 42% | 5h 30% | " + tr("semana", "week") + " 12%\n")
        let m = try #require(readFile(SessionMetrics.self, at: p.metrics("s1")))
        #expect(m == SessionMetrics(updated: 50, ctx: 42, model: "Opus", project: "api"))
        let l = try #require(readFile(LimitsFile.self, at: p.limits))
        #expect(l.fiveHour == .init(pct: 30, resets: 9_999_999_999))
        #expect(l.sevenDay == .init(pct: 12, resets: 0))
        #expect(l.updated == 50)
    }

    @Test func yourPreviousStatusLineGetsTheSameInput() throws {
        let home = TemporaryHome(), p = home.paths
        try "cat".write(to: p.previousStatusLine, atomically: true, encoding: .utf8)
        #expect(statusLine(input: input, paths: p, now: 50) == input)
        #expect(readFile(LimitsFile.self, at: p.limits)?.fiveHour?.pct == 30)   // Psiu still saves what it needs
    }

    @Test func aStuckPreviousStatusLineGivesWayToPsius() throws {
        let home = TemporaryHome(), p = home.paths
        try "sleep 10; echo late".write(to: p.previousStatusLine, atomically: true, encoding: .utf8)
        let start = Date()
        let out = statusLine(input: input, paths: p, now: 50, previousTimeout: 0.5)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(text(out).hasPrefix(tr("contexto", "context") + " 42%"))
    }
}
