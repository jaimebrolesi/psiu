import Foundation

/// Which sounds to play, and when to remind you again. Opening the panel counts as having seen everything.
public struct SoundPolicy: Sendable {
    /// Episodes (Session.key) you have already seen: no more sounds for them.
    public private(set) var seen = Set<String>()
    private var known = Set<String>()
    private var lastSound: [String: Date] = [:]
    private var reminders: [String: Int] = [:]
    private var panicked = Set<String>()      // waiting episodes that already played the panic sound
    private var firstLoad = true

    public init() {}

    /// The sounds to play now, by name. On the first pass, nothing plays for what was already going on.
    public mutating func sounds(for sessions: [Session], now: Date) -> [String] {
        var out: [String] = []
        func play(_ name: String, _ k: String) { lastSound[k] = now; out.append(name) }
        let active = Set(sessions.map(\.key))
        for s in sessions {
            let k = s.key
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
                    if panicked.insert(k).inserted { play(Sounds.panic, k) }
                    else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.panicInterval { play(Sounds.panic, k) }
                } else if isNew { play(Sounds.permission, k) }
                else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.permissionReminderInterval,
                        n < Sounds.maxPermissionReminders {
                    play(Sounds.permission, k); reminders[k] = n + 1
                }
            case .done:
                // Waits 3 s: if another task wakes Claude right after, it doesn't play for nothing.
                if lastSound[k] == nil {
                    if now.timeIntervalSince1970 - s.since >= 3 { play(Sounds.finished, k) }
                } else if let u = lastSound[k], now.timeIntervalSince(u) > Sounds.finishedReminderInterval, n < 1 {
                    play(Sounds.finished, k); reminders[k] = n + 1
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
        firstLoad = false
        return out
    }

    /// Opening the panel: everything finished or waiting counts as seen.
    public mutating func acknowledge(_ sessions: [Session]) {
        for s in sessions where s.state == .done || s.state == .awaiting { seen.insert(s.key) }
    }
}
