import Foundation
import Testing
@testable import PsiuCore

@Suite("Wait levels")
struct WaitLevelsTests {
    @Test func panicFromTenMinutesAndBurntFromThirty() {
        let now = 10_000.0
        let levels = WaitLevels(sessions: [
            session("fresh", .awaiting, since: now - 599),
            session("panic", .awaiting, since: now - 600),
            session("almost", .awaiting, since: now - 1799),
            session("burnt", .awaiting, since: now - 1800),
            session("working", .running, since: now - 5000),
        ], now: now)
        #expect(levels.panic == ["panic", "almost"])
        #expect(levels.burnt == ["burnt"])
    }

    @Test func aBurntSessionThatYouAnsweredRevives() {
        let now = 10_000.0
        let before = WaitLevels(sessions: [session("a", .awaiting, since: now - 2000)], now: now)
        let answered = [session("a", .running, since: now)]
        #expect(WaitLevels(sessions: answered, now: now).revives(from: before, sessions: answered))
        // Ending the session isn't a revival: it is simply gone.
        #expect(!WaitLevels(sessions: [], now: now).revives(from: before, sessions: []))
        // Still waiting: still burnt.
        let waiting = [session("a", .awaiting, since: now - 2000)]
        #expect(!WaitLevels(sessions: waiting, now: now).revives(from: before, sessions: waiting))
    }
}

@Suite("Usage forecast")
struct UsageForecasterTests {
    func limits(_ pct: Double, at t: Double, resets: Double) -> LimitsFile {
        var l = LimitsFile()
        l.fiveHour = .init(pct: pct, resets: resets)
        l.updated = 1000 + t   // readings are timestamps, never 0
        return l
    }

    @Test func needsFiveMinutesOfSamples() {
        var f = UsageForecaster()
        f.record(limits(10, at: 0, resets: 11_000))
        f.record(limits(20, at: 299, resets: 11_000))
        #expect(f.overflow == nil)
        #expect(!f.headroom)
    }

    @Test func aFastPaceRunsOutBeforeTheReset() {
        var f = UsageForecaster()
        f.record(limits(10, at: 0, resets: 11_000))
        f.record(limits(20, at: 600, resets: 11_000))   // 10% every 10 min: the other 80% in 80 min
        #expect(abs((f.overflow ?? 0) - 6400) < 0.001)
        #expect(!f.headroom)
    }

    @Test func aSlowPaceHasHeadroom() {
        var f = UsageForecaster()
        f.record(limits(10, at: 0, resets: 3000))
        f.record(limits(11, at: 600, resets: 3000))
        #expect(f.overflow == nil)
        #expect(f.headroom)
    }

    @Test func aNewWindowStartsOver() {
        var f = UsageForecaster()
        f.record(limits(10, at: 0, resets: 11_000))
        f.record(limits(20, at: 600, resets: 11_000))
        f.record(limits(1, at: 700, resets: 31_000))
        #expect(f.overflow == nil)
        #expect(!f.headroom)
    }

    @Test func theSameReadingIsOnlyCountedOnce() {
        var f = UsageForecaster()
        f.record(limits(10, at: 0, resets: 11_000))
        f.record(limits(20, at: 600, resets: 11_000))
        f.record(limits(20, at: 600, resets: 11_000))
        #expect(abs((f.overflow ?? 0) - 6400) < 0.001)
    }

    @Test func aResetWindowShowsZero() {
        #expect(UsageWindow(.init(pct: 40, resets: 100), now: 50) == UsageWindow(pct: 40, resetsAt: 100))
        #expect(UsageWindow(.init(pct: 40, resets: 100), now: 150)?.pct == 0)
        #expect(UsageWindow(nil, now: 0) == nil)
    }
}

@Suite("Scoreboard")
struct ScoreboardTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsWorkingAndWaitingTime() {
        var t = ScoreboardTracker()
        let sessions = [session("a", .running, since: 0), session("b", .awaiting, since: start.timeIntervalSince1970)]
        for i in 0...4 { _ = t.tick(now: start.addingTimeInterval(Double(i) * 0.5), sessions: sessions) }
        #expect(t.today.working == 2)
        #expect(t.today.waiting == 2)
        #expect(t.weekWaiting == 2)
    }

    @Test func aLongPauseCountsAtMostTwoSeconds() {
        var t = ScoreboardTracker()
        let sessions = [session("a", .running, since: 0)]
        _ = t.tick(now: start, sessions: sessions)
        _ = t.tick(now: start.addingTimeInterval(60), sessions: sessions)
        #expect(t.today.working == 2)
    }

    @Test func countsYourRepliesAndHowLongTheyTook() {
        var t = ScoreboardTracker()
        let asked = start.timeIntervalSince1970
        _ = t.tick(now: start, sessions: [session("a", .awaiting, since: asked)])
        _ = t.tick(now: start.addingTimeInterval(30), sessions: [session("a", .running, since: asked + 30)])
        #expect(t.today.replyCount == 1)
        #expect(t.today.replyTime == 30)
    }

    @Test func eachBurnCountsOnce() {
        var t = ScoreboardTracker()
        let asked = start.timeIntervalSince1970
        let waiting = [session("a", .awaiting, since: asked)]
        _ = t.tick(now: start.addingTimeInterval(1799), sessions: waiting)
        for s in 0..<5 { _ = t.tick(now: start.addingTimeInterval(1800 + Double(s)), sessions: waiting) }
        #expect(t.today.burnt == 1)
    }

    @Test func aSessionAlreadyBurntWhenPsiuOpensIsNotCounted() {
        var t = ScoreboardTracker()
        _ = t.tick(now: start, sessions: [session("a", .awaiting, since: start.timeIntervalSince1970 - 4000)])
        #expect(t.today.burnt == 0)
    }

    @Test func savesEveryTwentyTicks() {
        var t = ScoreboardTracker()
        let saves = (0..<40).filter { t.tick(now: start.addingTimeInterval(Double($0) * 0.5), sessions: []) }
        #expect(saves == [19, 39])
    }

    @Test func keepsSevenDaysOnDiskNamesInPortuguese() throws {
        var t = ScoreboardTracker(ScoreboardFile(days: ["2000-01-01": ["esp": 99], "keep": [:]]))
        _ = t.tick(now: start, sessions: [session("a", .running, since: 0)])
        _ = t.tick(now: start.addingTimeInterval(1), sessions: [session("a", .running, since: 0)])
        let days = t.file.days
        #expect(days.count == 1)
        let today = try #require(days.values.first)
        #expect(today["trab"] == 1)
        let encoded = try #require(String(data: JSONEncoder().encode(t.file), encoding: .utf8))
        #expect(encoded.contains("\"dias\""))
    }
}

@Suite("Sounds")
struct SoundPolicyTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var t: Double { now.timeIntervalSince1970 }

    @Test func nothingPlaysForWhatWasGoingOnAtLaunch() {
        var p = SoundPolicy()
        #expect(p.sounds(for: [session("a", .awaiting, since: t - 5), session("b", .done, since: t - 60)], now: now).isEmpty)
    }

    @Test func aNewPermissionPlaysAndRemindsEveryTwoMinutes() {
        var p = SoundPolicy()
        _ = p.sounds(for: [], now: now)
        let s = [session("a", .awaiting, since: t)]
        #expect(p.sounds(for: s, now: now) == [Sounds.permission])
        #expect(p.sounds(for: s, now: now.addingTimeInterval(60)).isEmpty)
        #expect(p.sounds(for: s, now: now.addingTimeInterval(121)) == [Sounds.permission])
    }

    @Test func finishedWaitsThreeSecondsAndRemindsOnce() {
        var p = SoundPolicy()
        _ = p.sounds(for: [], now: now)
        let s = [session("a", .done, since: t)]
        #expect(p.sounds(for: s, now: now.addingTimeInterval(1)).isEmpty)
        #expect(p.sounds(for: s, now: now.addingTimeInterval(3)) == [Sounds.finished])
        #expect(p.sounds(for: s, now: now.addingTimeInterval(184)) == [Sounds.finished])
        #expect(p.sounds(for: s, now: now.addingTimeInterval(400)).isEmpty)
    }

    @Test func openingThePanelSilencesTheReminders() {
        var p = SoundPolicy()
        _ = p.sounds(for: [], now: now)
        let s = [session("a", .awaiting, since: t)]
        _ = p.sounds(for: s, now: now)
        p.acknowledge(s)
        #expect(p.seen == [s[0].key])
        #expect(p.sounds(for: s, now: now.addingTimeInterval(200)).isEmpty)
    }

    @Test func panicEveryMinuteThenSilenceWhenBurnt() {
        var p = SoundPolicy()
        _ = p.sounds(for: [], now: now)
        let s = [session("a", .awaiting, since: t - 600)]
        #expect(p.sounds(for: s, now: now) == [Sounds.panic])
        #expect(p.sounds(for: s, now: now.addingTimeInterval(30)).isEmpty)
        #expect(p.sounds(for: s, now: now.addingTimeInterval(61)) == [Sounds.panic])
        #expect(p.sounds(for: s, now: now.addingTimeInterval(1200)).isEmpty)
    }
}
