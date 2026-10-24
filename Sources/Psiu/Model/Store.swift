import AppKit
import Observation
import PsiuCore

/// What the notch shows, read from the files the hooks write. Views observe it; the work is done by PsiuCore.
@Observable @MainActor
final class Store {
    private(set) var sessions: [Session] = []
    private(set) var fiveHour: UsageWindow?
    private(set) var week: UsageWindow?
    var muted = false
    private(set) var today = Scoreboard()
    private(set) var weekWaiting: Double = 0
    private(set) var forecast: Double?          // when the 5-hour window runs out, if that happens before it resets
    private(set) var forecastHeadroom = false   // the current pace fits in the window
    private(set) var waitLevels = WaitLevels()  // sessions in panic (10 to 30 min) or burnt (30 min or more)
    private(set) var revivingUntil: Date?       // a burnt Psiu shaking off the soot
    private(set) var relief: ReliefCue?         // a Psiu you answered, breathing out of yellow or red
    var displayAsleep = false                   // nobody can see the robot: screens asleep, locked or another user
    /// Episodes already seen (opening the panel): mirrored from the sound policy, as the robot's color depends on it.
    private(set) var seen = Set<String>()

    @ObservationIgnored private let paths: PsiuPaths
    @ObservationIgnored private let repository: SessionRepository
    @ObservationIgnored private var tracker: ScoreboardTracker
    @ObservationIgnored private var forecaster = UsageForecaster()
    @ObservationIgnored private var policy = SoundPolicy()
    @ObservationIgnored private var answered = AnsweredWaits()

    init(paths: PsiuPaths = .current) {
        self.paths = paths
        repository = SessionRepository(paths: paths)
        tracker = ScoreboardTracker(readFile(ScoreboardFile.self, at: paths.scoreboard))
    }

    /// A working session (or one running background tasks) is above 80% of its context.
    var heavyContext: Bool {
        sessions.contains { ($0.state == .running || $0.state == .background) && ($0.ctx ?? 0) >= 80 }
    }
    /// A compacted session finished and you haven't seen it yet: the green Psiu wears a purple headband.
    var bandaged: Bool {
        sessions.contains { $0.state == .done && $0.compactions > 0 && !seen.contains($0.key) }
    }
    var greenDot: Bool {
        color != .green && sessions.contains { $0.state == .done && !seen.contains($0.key) }
    }

    var color: RobotColor {
        if !waitLevels.panic.isEmpty { return .red }
        if !waitLevels.burnt.isEmpty { return .burnt }
        if sessions.contains(where: { $0.state == .awaiting }) { return .yellow }
        if sessions.contains(where: { $0.state == .running }) { return .blue }
        if sessions.contains(where: { $0.state == .background }) { return .backgroundBlue }
        if sessions.contains(where: { $0.state == .done && !seen.contains($0.key) }) { return .green }
        return sessions.isEmpty ? .gray : .dimGreen
    }

    /// Runs every half second. Properties are only set when they change, so views only redraw then.
    func reload() {
        let now = Date().timeIntervalSince1970
        let before = (color: color, sessions: sessions)
        let list = answered.apply(repository.sessions(now: now))
        if list != sessions { sessions = list }

        let levels = WaitLevels(sessions: sessions, now: now)
        let revives = levels.revives(from: waitLevels, sessions: sessions)
        if revives { revive() }
        if levels != waitLevels { waitLevels = levels }
        // Out of yellow or red, once nothing waits anymore, Psiu breathes out with relief (burnt, it revives).
        let waiting: [RobotColor] = [.yellow, .red, .burnt]
        if !revives, before.color == .yellow || before.color == .red, !waiting.contains(color),
           WaitLevels.answered(from: before.sessions, to: sessions) {
            breatheOut(from: before.color)
        }

        if let l = repository.limits() {
            let c = UsageWindow(l.fiveHour, now: now), w = UsageWindow(l.sevenDay, now: now)
            if c != fiveHour { fiveHour = c }
            if w != week { week = w }
            forecaster.record(l)
            if forecaster.overflow != forecast { forecast = forecaster.overflow }
            if forecaster.headroom != forecastHeadroom { forecastHeadroom = forecaster.headroom }
        }

        if tracker.tick(now: Date(), sessions: sessions) { writeFile(tracker.file, to: paths.scoreboard) }
        if tracker.today != today { today = tracker.today }
        if tracker.weekWaiting != weekWaiting { weekWaiting = tracker.weekWaiting }

        for name in policy.sounds(for: sessions, now: Date()) where !muted { NSSound(named: NSSound.Name(name))?.play() }
        if policy.seen != seen { seen = policy.seen }
        repository.endPass()
    }

    /// A burnt Psiu shakes off the soot (RobotRevival.duration), then the robot goes back to normal.
    private func revive() {
        let until = Date().addingTimeInterval(RobotRevival.duration)
        revivingUntil = until
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(RobotRevival.duration * 1000) + 50))
            guard let self, self.revivingUntil == until else { return }
            self.revivingUntil = nil
        }
    }

    /// Clicking a session waiting for you means you went to answer it: Claude Code says nothing when you approve
    /// a permission until the tool ends. Psiu reacts as to any answer (see reload).
    func answer(_ s: Session) {
        guard answered.answer(s, now: Date().timeIntervalSince1970) else { return }
        reload()
    }

    /// Relief (RobotRelief.duration), then the robot goes on in its new state.
    private func breatheOut(from: RobotColor) {
        let cue = ReliefCue(from: from, until: Date().addingTimeInterval(RobotRelief.duration))
        relief = cue
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(RobotRelief.duration * 1000) + 50))
            guard let self, self.relief == cue else { return }
            self.relief = nil
        }
    }

    /// Opening the panel counts as "seen" for the sound reminders.
    func acknowledge() {
        policy.acknowledge(sessions)
        if policy.seen != seen { seen = policy.seen }
    }
}
