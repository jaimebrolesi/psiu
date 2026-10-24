import Foundation

/// How long sessions have been waiting for you: 10 to 30 min is panic, 30 min or more is burnt.
public struct WaitLevels: Equatable, Sendable {
    public var panic = Set<String>()   // session IDs
    public var burnt = Set<String>()

    public init() {}

    public init(sessions: [Session], now: Double) {
        for s in sessions where s.state == .awaiting {
            let waited = now - s.since
            if waited >= Sounds.burnAfter { burnt.insert(s.id) } else if waited >= Sounds.panicAfter { panic.insert(s.id) }
        }
    }

    /// A burnt Psiu whose session stopped waiting shakes off the soot before taking the new state.
    public func revives(from previous: WaitLevels, sessions: [Session]) -> Bool {
        previous.burnt.subtracting(burnt).contains { id in sessions.contains { $0.id == id && $0.state != .awaiting } }
    }

    /// A session stopped waiting for you and is still open: you answered it (one that ended is simply gone).
    public static func answered(from previous: [Session], to sessions: [Session]) -> Bool {
        previous.contains { old in old.state == .awaiting && sessions.contains { $0.id == old.id && $0.state != .awaiting } }
    }
}
