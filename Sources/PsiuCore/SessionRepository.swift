import Foundation

/// Reads the sessions and plan limits that the hooks and the status line write, every half second.
/// Files that didn't change since the last pass aren't read again.
public final class SessionRepository {
    public let paths: PsiuPaths
    private var cache: [String: (date: Date, value: Any)] = [:]
    private var filesSeen = Set<String>()

    public init(paths: PsiuPaths) { self.paths = paths }

    private func cached<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        let path = url.path
        filesSeen.insert(path)
        // FileManager instead of URL resource values: URLs cache those, and some of these URLs live long.
        guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            cache[path] = nil
            return nil
        }
        if let c = cache[path], c.date == date, let value = c.value as? T { return value }
        guard let value = readFile(T.self, at: url) else { cache[path] = nil; return nil }
        cache[path] = (date, value)
        return value
    }

    /// The open sessions, newest first. Sessions abandoned for more than 12 h are deleted.
    public func sessions(now: Double) -> [Session] {
        var list: [Session] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: paths.sessions, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "json" && !url.lastPathComponent.hasSuffix(".metrics.json") {
            guard let r = cached(SessionRecord.self, url) else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            let metricsURL = paths.metrics(id)
            let updated = r.updated ?? 0
            if now - updated > 12 * 3600 {   // session abandoned for more than 12 h
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: metricsURL)
                continue
            }
            var s = Session(id: id,
                            project: r.project ?? tr("sessão", "session"),
                            state: SessionState(rawValue: r.state ?? "") ?? .idle,
                            since: r.since ?? updated,
                            updated: updated,
                            bg: r.bg,
                            summary: r.summary,
                            tty: r.tty,
                            bundle: r.bundle,
                            termprog: r.termprog,
                            compactions: r.compactions ?? 0)
            if let m = cached(SessionMetrics.self, metricsURL) {
                s.ctx = m.ctx
                s.model = m.model
                if r.project == nil, let p = m.project { s.project = p }
            }
            list.append(s)
        }
        list.sort { $0.since > $1.since }
        return list
    }

    public func limits() -> LimitsFile? { cached(LimitsFile.self, paths.limits) }

    /// Forgets files that weren't read in this pass (sessions that ended).
    public func endPass() {
        cache = cache.filter { filesSeen.contains($0.key) }
        filesSeen = []
    }
}
