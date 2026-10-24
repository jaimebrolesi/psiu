import AppKit
import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var fiveHour: UsageWindow?
    @Published var week: UsageWindow?
    @Published var muted = false
    @Published var today = Scoreboard()
    @Published var weekWaiting: Double = 0
    @Published var forecast: Double?          // when the 5-hour window runs out, if that happens before it resets
    @Published var forecastHeadroom = false   // the current pace fits in the window
    @Published var panicIDs = Set<String>()   // sessions waiting for you for 10 to 30 min
    @Published var burntIDs = Set<String>()   // sessions waiting for 30 min or more
    @Published var revivingUntil: Date?       // a burnt Psiu shaking off the soot
    @Published var displayAsleep = false      // nobody can see the robot: screens asleep, locked or another user

    private var days: [String: [String: Double]] = [:]
    private var lastTick: Date?
    private var ticks = 0
    private var previouslyAwaiting: [String: Double] = [:]
    private var samples: [(t: Double, p: Double)] = []
    private var currentResets: Double = 0
    private var lastLimitsRead: Double = 0
    private var belowBurn = Set<String>()     // waiting episodes seen before 30 min, so each burn counts once
    private var panicked = Set<String>()      // waiting episodes that already played the panic sound

    init() {
        if let d = readJSON(scoreboardFile)?["dias"] as? [String: [String: Double]] { days = d }
    }

    /// A working session (or one running background tasks) is above 80% of its context.
    var heavyContext: Bool {
        sessions.contains { ($0.state == .running || $0.state == .background) && ($0.ctx ?? 0) >= 80 }
    }
    /// A compacted session finished and you haven't seen it yet: the green Psiu wears a purple headband.
    var bandaged: Bool {
        sessions.contains { $0.state == .done && $0.compactions > 0 && !seen.contains(sessionKey($0)) }
    }
    var greenDot: Bool {
        color != .green && sessions.contains { $0.state == .done && !seen.contains(sessionKey($0)) }
    }

    private var seen = Set<String>()
    private var known = Set<String>()
    private var lastSound: [String: Date] = [:]
    private var reminders: [String: Int] = [:]
    private var firstLoad = true

    func sessionKey(_ s: Session) -> String { "\(s.id)|\(s.state.rawValue)|\(Int(s.since))" }

    var color: RobotColor {
        if !panicIDs.isEmpty { return .red }
        if !burntIDs.isEmpty { return .burnt }
        if sessions.contains(where: { $0.state == .awaiting }) { return .yellow }
        if sessions.contains(where: { $0.state == .running }) { return .blue }
        if sessions.contains(where: { $0.state == .background }) { return .backgroundBlue }
        if sessions.contains(where: { $0.state == .done && !seen.contains(sessionKey($0)) }) { return .green }
        return sessions.isEmpty ? .gray : .dimGreen
    }

    /// Parsed JSON files and their modification dates, so unchanged files aren't read again every half second.
    private var fileCache: [String: (date: Date, json: [String: Any])] = [:]
    private var filesSeen = Set<String>()

    private func readCached(_ url: URL) -> [String: Any]? {
        let path = url.path
        filesSeen.insert(path)
        // FileManager instead of URL resource values: URLs cache those, and limitsFile is a long-lived constant.
        guard let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            fileCache[path] = nil
            return nil
        }
        if let cached = fileCache[path], cached.date == date { return cached.json }
        guard let json = readJSON(url) else { fileCache[path] = nil; return nil }
        fileCache[path] = (date, json)
        return json
    }

    func reload() {
        let now = Date().timeIntervalSince1970
        var list: [Session] = []
        filesSeen = []
        let files = (try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".metrics.json") {
            guard let r = readCached(url) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let metricsURL = sessionsDir.appendingPathComponent("\(id).metrics.json")
            let updated = num(r["updated"]) ?? 0
            if now - updated > 12 * 3600 {   // session abandoned for more than 12 h
                try? fm.removeItem(at: url)
                try? fm.removeItem(at: metricsURL)
                continue
            }
            var s = Session(id: id,
                           project: r["project"] as? String ?? tr("sessão", "session"),
                           state: SessionState(rawValue: r["state"] as? String ?? "") ?? .idle,
                           since: num(r["since"]) ?? updated,
                           updated: updated,
                           bg: r["bg"] as? String,
                           summary: r["resumo"] as? String,
                           tty: r["tty"] as? String,
                           bundle: r["bundle"] as? String,
                           termprog: r["termprog"] as? String,
                           compactions: Int(num(r["compactacoes"]) ?? 0))
            if let m = readCached(metricsURL) {
                s.ctx = num(m["ctx"])
                s.model = m["model"] as? String
                if r["project"] == nil, let p = m["project"] as? String { s.project = p }
            }
            list.append(s)
        }
        list.sort { $0.since > $1.since }
        if list != sessions { sessions = list }
        updateWaitLevels(now)

        if let l = readCached(limitsFile) {
            let c = usageWindow(l["five_hour"], now), w = usageWindow(l["seven_day"], now)
            if c != fiveHour { fiveHour = c }
            if w != week { week = w }
            recordSample(l)
        }
        updateScoreboard(Date())
        playSoundsIfNeeded()
        firstLoad = false
        fileCache = fileCache.filter { filesSeen.contains($0.key) }
    }

    // MARK: Panic and burnt Psiu

    private func updateWaitLevels(_ now: Double) {
        var panic = Set<String>(), burnt = Set<String>()
        for s in sessions where s.state == .awaiting {
            let waited = now - s.since
            if waited >= Sounds.burnAfter { burnt.insert(s.id) } else if waited >= Sounds.panicAfter { panic.insert(s.id) }
        }
        // A burnt Psiu whose session stopped waiting shakes off the soot before taking the new state.
        let revived = burntIDs.subtracting(burnt).contains { id in
            sessions.contains { $0.id == id && $0.state != .awaiting }
        }
        if revived {
            revivingUntil = Date().addingTimeInterval(0.8)
            // Once it's over, clear it, so the robot goes back to its usual frame rate.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let until = self.revivingUntil, until <= Date() else { return }
                    self.revivingUntil = nil
                }
            }
        }
        if panic != panicIDs { panicIDs = panic }
        if burnt != burntIDs { burntIDs = burnt }
    }

    // MARK: 5-hour window forecast

    private func recordSample(_ l: [String: Any]) {
        guard let readAt = num(l["updated"]), readAt != lastLimitsRead,
              let fh = l["five_hour"] as? [String: Any], let p = num(fh["pct"]) else { return }
        lastLimitsRead = readAt
        let r = num(fh["resets"]) ?? 0
        if r != currentResets { samples = []; currentResets = r }
        samples.append((readAt, p))
        samples = samples.filter { readAt - $0.t <= 3600 }   // pace over the last hour

        var overflow: Double?
        var headroom = false
        if let a = samples.first, let b = samples.last, b.t - a.t >= 300 {
            if b.p > a.p {
                let rate = (b.p - a.p) / (b.t - a.t)
                let fullAt = b.t + (100 - b.p) / rate
                if currentResets > 0 && fullAt < currentResets { overflow = fullAt } else { headroom = true }
            } else {
                headroom = true
            }
        }
        if overflow != forecast { forecast = overflow }
        if headroom != forecastHeadroom { forecastHeadroom = headroom }
    }

    // MARK: Today's scoreboard

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private var lastWeek: (today: String, days: [String])?

    private func dayKey(_ d: Date) -> String { Self.dayFormatter.string(from: d) }

    /// Today and the six days before it, worked out again only when the day changes.
    private func last7DayKeys(_ now: Date) -> [String] {
        let today = dayKey(now)
        if let w = lastWeek, w.today == today { return w.days }
        let days = (0..<7).map { dayKey(now.addingTimeInterval(-Double($0) * 86400)) }
        lastWeek = (today, days)
        return days
    }

    private func updateScoreboard(_ now: Date) {
        let dt = min(lastTick.map { now.timeIntervalSince($0) } ?? 0, 2)
        lastTick = now
        let day = dayKey(now)
        var d = days[day] ?? [:]
        if sessions.contains(where: { $0.state == .running || $0.state == .background }) { d["trab", default: 0] += dt }
        if sessions.contains(where: { $0.state == .awaiting }) { d["esp", default: 0] += dt }

        var awaitingNow: [String: Double] = [:]
        for s in sessions where s.state == .awaiting { awaitingNow[sessionKey(s)] = s.since }
        for (k, since) in previouslyAwaiting where awaitingNow[k] == nil {
            d["nResp", default: 0] += 1
            d["tResp", default: 0] += max(0, now.timeIntervalSince1970 - since)
        }
        previouslyAwaiting = awaitingNow
        // Each waiting episode that crosses 30 min burns one Psiu, counted once.
        for s in sessions where s.state == .awaiting {
            let k = sessionKey(s)
            if now.timeIntervalSince1970 - s.since < Sounds.burnAfter { belowBurn.insert(k) }
            else if belowBurn.remove(k) != nil { d["queim", default: 0] += 1 }
        }
        belowBurn.formIntersection(awaitingNow.keys)
        days[day] = d

        let last7Days = last7DayKeys(now)
        days = days.filter { last7Days.contains($0.key) }
        let h = Scoreboard(working: (d["trab"] ?? 0).rounded(), waiting: (d["esp"] ?? 0).rounded(),
                       replyCount: Int(d["nResp"] ?? 0), replyTime: d["tResp"] ?? 0, burnt: Int(d["queim"] ?? 0))
        if h != today { today = h }
        let weekWait = last7Days.reduce(0) { $0 + (days[$1]?["esp"] ?? 0) }.rounded()
        if weekWait != weekWaiting { weekWaiting = weekWait }

        ticks += 1
        if ticks >= 20 {   // saves every ~10 s
            ticks = 0
            writeJSON(["dias": days], to: scoreboardFile)
        }
    }

    private func usageWindow(_ v: Any?, _ now: Double) -> UsageWindow? {
        guard let d = v as? [String: Any], let p = num(d["pct"]) else { return nil }
        let r = num(d["resets"]) ?? 0
        if r > 0 && r < now { return UsageWindow(pct: 0, resetsAt: 0) }   // the window has already reset
        return UsageWindow(pct: p, resetsAt: r)
    }

    private func playSoundsIfNeeded() {
        let now = Date()
        let active = Set(sessions.map(sessionKey))
        for s in sessions {
            let k = sessionKey(s)
            let isNew = !known.contains(k)
            known.insert(k)
            if firstLoad {
                lastSound[k] = now
                reminders[k] = 99
                if s.state == .awaiting && now.timeIntervalSince1970 - s.since >= Sounds.panicAfter { panicked.insert(k) }
                continue
            }
            if seen.contains(k) { continue }
            let n = reminders[k] ?? 0
            switch s.state {
            case .awaiting:
                let waited = now.timeIntervalSince1970 - s.since
                if waited >= Sounds.burnAfter { break }   // burnt: silent
                if waited >= Sounds.panicAfter {
                    if panicked.insert(k).inserted { playSound(Sounds.panic, k) }
                    else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.panicInterval { playSound(Sounds.panic, k) }
                } else if isNew { playSound(Sounds.permission, k) }
                else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.permissionReminderInterval,
                        n < Sounds.maxPermissionReminders {
                    playSound(Sounds.permission, k); reminders[k] = n + 1
                }
            case .done:
                // Waits 3 s: if another task wakes Claude right after, it doesn't play for nothing.
                if lastSound[k] == nil {
                    if now.timeIntervalSince1970 - s.since >= 3 { playSound(Sounds.finished, k) }
                } else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.finishedReminderInterval, n < 1 {
                    playSound(Sounds.finished, k); reminders[k] = n + 1
                }
            default:
                break
            }
        }
        known.formIntersection(active)
        seen.formIntersection(active)
        panicked.formIntersection(active)
        lastSound = lastSound.filter { active.contains($0.key) }
        reminders = reminders.filter { active.contains($0.key) }
    }

    private func playSound(_ name: String, _ k: String) {
        lastSound[k] = Date()
        if !muted { NSSound(named: NSSound.Name(name))?.play() }
    }

    /// Opening the panel counts as "seen" for the sound reminders.
    func acknowledge() {
        for s in sessions where s.state == .done || s.state == .awaiting { seen.insert(sessionKey(s)) }
        objectWillChange.send()
    }
}
