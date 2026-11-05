import Darwin

/// Going back to a finished session's terminal counts as seeing it, as opening the panel does. Claude Code turns
/// on the terminal's focus reporting, so its tab coming to the front (or a key, or the mouse over it) is input to
/// Claude Code, and reading it moves the tty's access time; Claude Code reads nothing on its own once a turn ends.
/// A tab losing focus moves it too: when another app or the lock screen takes the focus, that app is in front or
/// the robot is hidden by the next pass, so a visit only counts when two passes in a row agree.
public struct TerminalVisits: Sendable {
    /// How fresh the input must be: a mouse that crossed the window a while ago is not you coming back.
    public static let recent: Double = 2
    private var pending = Set<String>()

    public init() {}

    /// The finished episodes you just went back to. `frontmost` is the app in front, nil while nobody can see the
    /// screen; `lastInput` is the tty's access time.
    public mutating func seen(in sessions: [Session], now: Double, frontmost: String?,
                              lastInput: (String) -> Double?) -> Set<String> {
        var visiting = Set<String>()
        for s in sessions where s.state == .done {
            guard let app = s.bundle, !app.isEmpty, app == frontmost,
                  let tty = s.tty, tty.hasPrefix("/dev/"), let input = lastInput(tty),
                  input > s.since, now - input < Self.recent else { continue }
            visiting.insert(s.key)
        }
        defer { pending = visiting }
        return visiting.intersection(pending)
    }

    /// When the terminal last sent something to the program on this tty.
    public static func lastInput(_ tty: String) -> Double? {
        var st = stat()
        guard stat(tty, &st) == 0 else { return nil }
        return Double(st.st_atimespec.tv_sec) + Double(st.st_atimespec.tv_nsec) / 1_000_000_000
    }
}
