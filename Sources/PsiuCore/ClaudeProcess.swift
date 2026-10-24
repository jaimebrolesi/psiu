import Darwin

/// The Claude Code process a session runs in. If it dies without SessionEnd (a closed terminal, a crash), the
/// session would otherwise stay "working" for up to 12 hours. Its start time tells a reused pid apart.
public struct ClaudeProcess: Equatable, Sendable {
    public var pid: Int32
    public var start: Double

    public init(pid: Int32, start: Double) { self.pid = pid; self.start = start }

    /// The process that ran this hook: the nearest one above it that isn't a shell, since Claude Code may run
    /// hooks through `sh -c`.
    public static func current() -> ClaudeProcess? {
        var pid = getppid()
        for _ in 0..<4 {
            guard pid > 1, let info = bsdInfo(pid) else { return nil }
            let name = withUnsafeBytes(of: info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if !["sh", "bash", "zsh", "dash", "fish"].contains(name) {
                return ClaudeProcess(pid: pid, start: Double(info.pbi_start_tvsec))
            }
            pid = pid_t(info.pbi_ppid)
        }
        return nil
    }

    /// Still running, and still the same process (not another one that got its pid).
    public var isRunning: Bool {
        guard let info = Self.bsdInfo(pid) else { return errno != ESRCH }   // can't tell: assume it is
        return Double(info.pbi_start_tvsec) == start
    }

    static func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }
}
