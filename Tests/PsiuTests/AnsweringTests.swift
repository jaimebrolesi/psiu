import AppKit
import PsiuCore
import QuartzCore
import Testing
@testable import Psiu

/// Clicking a session that waits for you, in the panel: Claude Code sends nothing when you approve a permission.
@Suite("Answering from the panel")
@MainActor
final class AnsweringTests {
    let paths: PsiuPaths

    init() {
        paths = PsiuPaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("psiu-tests-\(UUID().uuidString)"))
        paths.ensureDirectories()
    }

    deinit { try? FileManager.default.removeItem(at: paths.home) }

    /// Sessions waiting for you for these many seconds.
    func store(waiting: [String: Double]) -> Store {
        let now = Date().timeIntervalSince1970
        for (id, waited) in waiting {
            var r = SessionRecord()
            r.state = "awaiting"
            r.since = now - waited
            r.updated = now
            writeFile(r, to: paths.session(id))
        }
        let store = Store(paths: paths)
        store.muted = true
        store.reload()
        return store
    }

    @Test func aYellowPsiuBreathesOutAndWorks() throws {
        let store = store(waiting: ["a": 30])
        #expect(store.color == .yellow)
        store.answer(try #require(store.sessions.first))
        #expect(store.color == .blue)
        #expect(store.sessions.first?.state == .running)
        #expect(store.relief?.from == .yellow)
        #expect(store.revivingUntil == nil)
    }

    @Test func aPanickingPsiuBreathesOutToo() throws {
        let store = store(waiting: ["a": 700])
        #expect(store.color == .red)
        store.answer(try #require(store.sessions.first))
        #expect(store.color == .blue)
        #expect(store.relief?.from == .red)
    }

    @Test func aBurntPsiuComesOutOfTheSmoke() throws {
        let store = store(waiting: ["a": 2000])
        #expect(store.color == .burnt)
        store.answer(try #require(store.sessions.first))
        #expect(store.color == .blue)
        #expect(store.revivingUntil != nil)
        #expect(store.relief == nil)
    }

    @Test func noReliefWhileAnotherSessionStillWaits() throws {
        let store = store(waiting: ["a": 30, "b": 20])
        store.answer(try #require(store.sessions.first { $0.id == "a" }))
        #expect(store.color == .yellow)
        #expect(store.relief == nil)
        #expect(store.sessions.first { $0.id == "a" }?.state == .running)
    }

    @Test func onlyAWaitingSessionCounts() throws {
        let store = store(waiting: [:])
        var r = SessionRecord()
        r.state = "done"
        r.since = Date().timeIntervalSince1970
        r.updated = r.since
        writeFile(r, to: paths.session("a"))
        store.reload()
        store.answer(try #require(store.sessions.first))
        #expect(store.sessions.first?.state == .done)
        #expect(store.relief == nil)
    }

    @Test func theNextEventTakesOver() throws {
        let store = store(waiting: ["a": 30])
        store.answer(try #require(store.sessions.first))
        var r = SessionRecord()
        r.state = "done"
        r.since = Date().timeIntervalSince1970 + 1
        r.updated = r.since
        writeFile(r, to: paths.session("a"))
        store.reload()
        #expect(store.sessions.first?.state == .done)
    }

    @Test func theReliefEnds() async throws {
        let store = store(waiting: ["a": 30])
        store.answer(try #require(store.sessions.first))
        #expect(store.relief != nil)
        try await Task.sleep(for: .milliseconds(Int(RobotRelief.duration * 1000) + 200))
        #expect(store.relief == nil)
    }
}

/// The robot's one-off animations reach Core Animation, with their length.
@Suite("Robot animations")
@MainActor
struct RobotAnimationTests {
    let blue = RobotLook(color: .blue, tired: false, peeking: false, bandaged: false)

    func view() -> RobotLayerView {
        let v = RobotLayerView()
        v.frame = CGRect(x: 0, y: 0, width: 42, height: 32)
        return v
    }

    /// Every animation under the view stored under `key`.
    func animations(_ key: String, in layer: CALayer?) -> [CAAnimation] {
        guard let layer else { return [] }
        return (layer.animation(forKey: key).map { [$0] } ?? []) + (layer.sublayers ?? []).flatMap { animations(key, in: $0) }
    }

    @Test func theReliefMovesTheHeadShellEyesAndPuff() {
        let v = view()
        v.update(look: blue, revivingUntil: nil,
                 relief: ReliefCue(from: .yellow, until: Date().addingTimeInterval(RobotRelief.duration)), paused: false)
        let relief = animations("relief", in: v.layer)
        #expect(relief.count == 4)   // breath, old shell fading, eyes hidden, shut eyes and puff
        #expect(relief.allSatisfy { $0.duration == RobotRelief.duration })
        #expect(RobotRelief.duration == 2)
    }

    @Test func theReliefAlsoStartsAfterTheColorChanged() {
        let v = view()
        v.update(look: RobotLook(color: .yellow, tired: false, peeking: false, bandaged: false), revivingUntil: nil, relief: nil, paused: false)
        v.update(look: blue, revivingUntil: nil, relief: nil, paused: false)
        #expect(animations("relief", in: v.layer).isEmpty)
        v.update(look: blue, revivingUntil: nil,
                 relief: ReliefCue(from: .yellow, until: Date().addingTimeInterval(RobotRelief.duration)), paused: false)
        #expect(animations("relief", in: v.layer).count == 4)
    }

    @Test func nothingMovesWhileNobodySees() {
        let v = view()
        v.update(look: blue, revivingUntil: Date().addingTimeInterval(1),
                 relief: ReliefCue(from: .red, until: Date().addingTimeInterval(1)), paused: true)
        #expect(animations("relief", in: v.layer).isEmpty)
        #expect(animations("revive", in: v.layer).isEmpty)
    }

    @Test func theRevivalShakesFadesAndSmokes() {
        let v = view()
        v.update(look: blue, revivingUntil: Date().addingTimeInterval(RobotRevival.duration), relief: nil, paused: false)
        let revive = animations("revive", in: v.layer)
        #expect(revive.count == 3)   // shake, burnt shell fading, smoke curtain
        #expect(revive.allSatisfy { $0.duration == RobotRevival.duration })
        #expect(RobotRevival.duration == 1.5)
    }
}
