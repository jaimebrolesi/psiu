import Foundation

// MARK: - Signal model

enum SessionState: String { case idle, running, background, awaiting, done }

enum RobotColor { case red, burnt, yellow, blue, backgroundBlue, green, dimGreen, gray }

struct Session: Identifiable, Equatable {
    let id: String
    var project: String
    var state: SessionState
    var since: Double
    var updated: Double
    var ctx: Double?
    var model: String?
    var bg: String?
    var summary: String?
    var tty: String?
    var bundle: String?
    var termprog: String?
    var compactions = 0
}

struct Scoreboard: Equatable {
    var working: Double = 0     // seconds with some agent working
    var waiting: Double = 0     // seconds with some session waiting for you
    var replyCount: Int = 0     // how many times you replied
    var replyTime: Double = 0   // sum of the times until you replied
    var burnt: Int = 0          // waiting episodes that crossed 30 min
}

let scoreboardFile = baseDir.appendingPathComponent("placar.json")

struct UsageWindow: Equatable {
    var pct: Double
    var resetsAt: Double
}

// Tune the sounds and reminder intervals here.
enum Sounds {
    static let permission = "Submarine"
    static let finished = "Glass"
    static let permissionReminderInterval: TimeInterval = 120   // repeats while it waits for you
    static let maxPermissionReminders = 15                      // at most 30 min of sounds
    static let finishedReminderInterval: TimeInterval = 180     // one extra reminder if you didn't come back
    static let panic = "Sosumi"
    static let panicInterval: TimeInterval = 60                 // repeats while Psiu panics
    static let panicAfter: TimeInterval = 600                   // waiting for you for 10 min: panic
    static let burnAfter: TimeInterval = 1800                   // 30 min: burnt, and silent
}
