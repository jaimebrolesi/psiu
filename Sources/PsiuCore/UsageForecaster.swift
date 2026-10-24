import Foundation

/// Based on the last hour, whether your pace runs out the 5-hour window before it resets.
public struct UsageForecaster: Sendable {
    private var samples: [(t: Double, p: Double)] = []
    private var currentResets: Double = 0
    private var lastRead: Double = 0
    /// When the 5-hour window runs out, if that happens before it resets.
    public private(set) var overflow: Double?
    /// The current pace fits in the window.
    public private(set) var headroom = false

    public init() {}

    public mutating func record(_ l: LimitsFile) {
        guard let readAt = l.updated, readAt != lastRead, let p = l.fiveHour?.pct else { return }
        lastRead = readAt
        let r = l.fiveHour?.resets ?? 0
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
        self.overflow = overflow
        self.headroom = headroom
    }
}
