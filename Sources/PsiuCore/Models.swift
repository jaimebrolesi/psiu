import Foundation

// MARK: - Files on disk

/// A session as the hooks write it, in ~/.psiu/sessions/<id>.json.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var state: String?
    public var since: Double?
    public var updated: Double?
    public var project: String?
    public var summary: String?
    public var bg: String?
    public var tty: String?
    public var bundle: String?
    public var termprog: String?
    public var compactions: Int?
    /// The Claude Code process, and when it started (see ClaudeProcess).
    public var pid: Int32?
    public var pidStart: Double?
    /// The agents with a permission dialog open ("" is the main agent).
    public var waiting: [String]?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case state, since, updated, project, bg, tty, bundle, termprog, pid, pidStart, waiting
        case summary = "resumo", compactions = "compactacoes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.lenient(String.self, .state)
        since = c.number(.since)
        updated = c.number(.updated)
        project = c.lenient(String.self, .project)
        summary = c.lenient(String.self, .summary)
        bg = c.lenient(String.self, .bg)
        tty = c.lenient(String.self, .tty)
        bundle = c.lenient(String.self, .bundle)
        termprog = c.lenient(String.self, .termprog)
        compactions = c.number(.compactions).map { Int($0) }
        pid = c.number(.pid).map { Int32($0) }
        pidStart = c.number(.pidStart)
        waiting = c.lenient([String].self, .waiting)
    }
}

/// What the status line learns about a session, in ~/.psiu/sessions/<id>.metrics.json.
public struct SessionMetrics: Codable, Equatable, Sendable {
    public var updated: Double?
    public var ctx: Double?
    public var model: String?
    public var project: String?

    public init(updated: Double? = nil, ctx: Double? = nil, model: String? = nil, project: String? = nil) {
        self.updated = updated; self.ctx = ctx; self.model = model; self.project = project
    }

    enum CodingKeys: String, CodingKey { case updated, ctx, model, project }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updated = c.number(.updated)
        ctx = c.number(.ctx)
        model = c.lenient(String.self, .model)
        project = c.lenient(String.self, .project)
    }
}

/// Plan limits from the status line, in ~/.psiu/limits.json.
public struct LimitsFile: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        public var pct: Double?
        public var resets: Double?

        public init(pct: Double?, resets: Double?) { self.pct = pct; self.resets = resets }

        enum CodingKeys: String, CodingKey { case pct, resets }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pct = c.number(.pct)
            resets = c.number(.resets)
        }
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var updated: Double?

    public init() {}

    enum CodingKeys: String, CodingKey { case fiveHour = "five_hour", sevenDay = "seven_day", updated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = c.lenient(Window.self, .fiveHour)
        sevenDay = c.lenient(Window.self, .sevenDay)
        updated = c.number(.updated)
    }
}

/// Preferences, in ~/.psiu/prefs.json.
public struct Prefs: Codable, Equatable, Sendable {
    public var muted: Bool?
    public var hiddenScreens: [String]?

    public init(muted: Bool? = nil, hiddenScreens: [String]? = nil) { self.muted = muted; self.hiddenScreens = hiddenScreens }

    enum CodingKeys: String, CodingKey { case muted = "mudo", hiddenScreens = "ocultas" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        muted = c.lenient(Bool.self, .muted)
        hiddenScreens = c.lenient([String].self, .hiddenScreens)
    }
}

/// Today and the six days before it, in ~/.psiu/placar.json: per day, "trab" and "esp" (seconds working and
/// waiting for you), "nResp" and "tResp" (replies and their total time) and "queim" (Psius burnt).
public struct ScoreboardFile: Codable, Equatable, Sendable {
    public var days: [String: [String: Double]]

    public init(days: [String: [String: Double]] = [:]) { self.days = days }

    enum CodingKeys: String, CodingKey { case days = "dias" }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.lenient([String: [String: Double]].self, .days) ?? [:]
    }
}

// MARK: - What the app shows

public enum SessionState: String, Sendable { case idle, running, background, awaiting, done }

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String
    public var project: String
    public var state: SessionState
    public var since: Double
    public var updated: Double
    public var ctx: Double?
    public var model: String?
    public var bg: String?
    public var summary: String?
    public var tty: String?
    public var bundle: String?
    public var termprog: String?
    public var compactions = 0

    public init(id: String, project: String, state: SessionState, since: Double, updated: Double,
                ctx: Double? = nil, model: String? = nil, bg: String? = nil, summary: String? = nil,
                tty: String? = nil, bundle: String? = nil, termprog: String? = nil, compactions: Int = 0) {
        self.id = id; self.project = project; self.state = state; self.since = since; self.updated = updated
        self.ctx = ctx; self.model = model; self.bg = bg; self.summary = summary
        self.tty = tty; self.bundle = bundle; self.termprog = termprog; self.compactions = compactions
    }

    /// One episode of a session: the same session in another state, or the same state again later, is another key.
    public var key: String { "\(id)|\(state.rawValue)|\(Int(since))" }
}

public struct Scoreboard: Equatable, Sendable {
    public var working: Double = 0     // seconds with some agent working
    public var waiting: Double = 0     // seconds with some session waiting for you
    public var replyCount: Int = 0     // how many times you replied
    public var replyTime: Double = 0   // sum of the times until you replied
    public var burnt: Int = 0          // waiting episodes that crossed 30 min

    public init(working: Double = 0, waiting: Double = 0, replyCount: Int = 0, replyTime: Double = 0, burnt: Int = 0) {
        self.working = working; self.waiting = waiting; self.replyCount = replyCount; self.replyTime = replyTime; self.burnt = burnt
    }
}

public struct UsageWindow: Equatable, Sendable {
    public var pct: Double
    public var resetsAt: Double

    public init(pct: Double, resetsAt: Double) { self.pct = pct; self.resetsAt = resetsAt }

    /// A plan window from limits.json, or 0% once its reset time has passed.
    public init?(_ w: LimitsFile.Window?, now: Double) {
        guard let w, let p = w.pct else { return nil }
        let r = w.resets ?? 0
        if r > 0 && r < now { self.init(pct: 0, resetsAt: 0) } else { self.init(pct: p, resetsAt: r) }   // the window has already reset
    }
}

// Tune the sounds and reminder intervals here.
public enum Sounds {
    public static let permission = "Submarine"
    public static let finished = "Glass"
    public static let permissionReminderInterval: TimeInterval = 120   // repeats while it waits for you
    public static let maxPermissionReminders = 15                      // at most 30 min of sounds
    public static let finishedReminderInterval: TimeInterval = 180     // one extra reminder if you didn't come back
    public static let panic = "Sosumi"
    public static let panicInterval: TimeInterval = 60                 // repeats while Psiu panics
    public static let panicAfter: TimeInterval = 600                   // waiting for you for 10 min: panic
    public static let burnAfter: TimeInterval = 1800                   // 30 min: burnt, and silent
}
