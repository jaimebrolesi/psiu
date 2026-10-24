import Foundation

/// Waits you answered by clicking the session in the panel. Claude Code sends no event when you approve a
/// permission (the next one comes when the tool ends), so the click stands in for it: the session shows as
/// working from then on, until its next event changes it anyway.
public struct AnsweredWaits: Sendable {
    private var answered: [String: Double] = [:]   // episode key → when you clicked

    public init() {}

    /// Whether the click answered something: only a session waiting for you.
    @discardableResult
    public mutating func answer(_ s: Session, now: Double) -> Bool {
        guard s.state == .awaiting else { return false }
        answered[s.key] = now
        return true
    }

    /// The sessions as the app shows them. A wait that ended or moved on by itself is forgotten.
    public mutating func apply(_ sessions: [Session]) -> [Session] {
        answered = answered.filter { key, _ in sessions.contains { $0.key == key } }
        return sessions.map { s in
            guard let at = answered[s.key] else { return s }
            var s = s
            s.state = .running
            s.since = at
            return s
        }
    }
}
