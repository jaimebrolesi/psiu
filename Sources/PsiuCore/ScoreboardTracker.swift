import Foundation

/// Today's scoreboard: time working and waiting for you, your replies and the Psius burnt, kept for 7 days.
public struct ScoreboardTracker {
    private(set) var days: [String: [String: Double]]
    private var lastTick: Date?
    private var ticks = 0
    private var previouslyAwaiting: [String: Double] = [:]
    private var belowBurn = Set<String>()     // waiting episodes seen before 30 min, so each burn counts once
    private var lastWeek: (today: String, days: [String])?
    public private(set) var today = Scoreboard()
    public private(set) var weekWaiting: Double = 0

    public init(_ file: ScoreboardFile? = nil) { days = file?.days ?? [:] }

    public var file: ScoreboardFile { ScoreboardFile(days: days) }

    // Only ever used for day keys.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dayKey(_ d: Date) -> String { Self.dayFormatter.string(from: d) }

    /// Today and the six days before it, worked out again only when the day changes.
    private mutating func last7DayKeys(_ now: Date) -> [String] {
        let today = dayKey(now)
        if let w = lastWeek, w.today == today { return w.days }
        let days = (0..<7).map { dayKey(now.addingTimeInterval(-Double($0) * 86400)) }
        lastWeek = (today, days)
        return days
    }

    /// Counts the time since the last tick. Returns true when it's time to save (every ~10 s).
    public mutating func tick(now: Date, sessions: [Session]) -> Bool {
        let dt = min(lastTick.map { now.timeIntervalSince($0) } ?? 0, 2)
        lastTick = now
        let day = dayKey(now)
        var d = days[day] ?? [:]
        if sessions.contains(where: { $0.state == .running || $0.state == .background }) { d["trab", default: 0] += dt }
        if sessions.contains(where: { $0.state == .awaiting }) { d["esp", default: 0] += dt }

        var awaitingNow: [String: Double] = [:]
        for s in sessions where s.state == .awaiting { awaitingNow[s.key] = s.since }
        for (k, since) in previouslyAwaiting where awaitingNow[k] == nil {
            d["nResp", default: 0] += 1
            d["tResp", default: 0] += max(0, now.timeIntervalSince1970 - since)
        }
        previouslyAwaiting = awaitingNow
        // Each waiting episode that crosses 30 min burns one Psiu, counted once.
        for s in sessions where s.state == .awaiting {
            let k = s.key
            if now.timeIntervalSince1970 - s.since < Sounds.burnAfter { belowBurn.insert(k) }
            else if belowBurn.remove(k) != nil { d["queim", default: 0] += 1 }
        }
        belowBurn.formIntersection(awaitingNow.keys)
        days[day] = d

        let last7Days = last7DayKeys(now)
        days = days.filter { last7Days.contains($0.key) }
        today = Scoreboard(working: (d["trab"] ?? 0).rounded(), waiting: (d["esp"] ?? 0).rounded(),
                           replyCount: Int(d["nResp"] ?? 0), replyTime: d["tResp"] ?? 0, burnt: Int(d["queim"] ?? 0))
        weekWaiting = last7Days.reduce(0) { $0 + (days[$1]?["esp"] ?? 0) }.rounded()

        ticks += 1
        if ticks >= 20 {   // saves every ~10 s
            ticks = 0
            return true
        }
        return false
    }
}
