import AppKit
import SwiftUI

struct DetailView: View {
    @ObservedObject var store: Store
    var onOpen: (Session) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LimitView(title: tr("Sessão de 5 horas", "5-hour session"), usageWindow: store.fiveHour, format: "HH:mm",
                       overflow: store.forecast, headroom: store.forecastHeadroom)
            LimitView(title: tr("Semana", "Week"), usageWindow: store.week, format: "EEE HH:mm")
            Divider()
            if store.sessions.isEmpty {
                Text(tr("Nenhuma sessão do Claude Code aberta.", "No Claude Code sessions open."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(store.sessions.prefix(5)) { s in
                    SessionView(s: s)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpen(s) }
                }
            }
            Divider()
            ScoreboardView(today: store.today, weekWaiting: store.weekWaiting)
            VersionView()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LimitView: View {
    let title: String
    let usageWindow: UsageWindow?
    let format: String
    var overflow: Double? = nil
    var headroom = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                if let j = usageWindow {
                    Text("\(Int(j.pct.rounded()))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                }
            }
            if let j = usageWindow {
                GeometryReader { geo in
                    let w = geo.size.width
                    let used = w * CGFloat(min(j.pct, 100) / 100)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        if overflow != nil {
                            Rectangle().fill(Color(hex: 0xEF9F27, alpha: 0.4))
                                .frame(width: max(0, w - used)).offset(x: used)
                        }
                        Capsule().fill(usageColor(j.pct)).frame(width: used)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                HStack {
                    Text(resetText(j)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if let e = overflow {
                        Text(tr("No ritmo atual, acaba às ", "At this pace, runs out at ") + shortTime(e))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0xFAC775))
                    } else if headroom {
                        Text(tr("No ritmo atual, dá folga", "At this pace, plenty left")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(tr("Aparece depois da primeira resposta numa sessão.", "Shows up after the first reply in a session."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    func resetText(_ j: UsageWindow) -> String {
        guard j.resetsAt > 0 else { return tr("Janela renovada", "Window reset") }
        return tr("Renova ", "Resets ") + shortTime(j.resetsAt, format)
    }
}

struct SessionView: View {
    let s: Session

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(waited >= Sounds.panicAfter ? Color(hex: 0xE24B4A)
                          : isHeavy ? Color(hex: 0xAFA9EC) : stateColor(s.state))
                .frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.project).font(.system(size: 12, weight: .semibold))
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                    if s.compactions > 0 {
                        Text(tr("compactada \(s.compactions)x", "compacted \(s.compactions)x"))
                            .font(.system(size: 10)).foregroundStyle(Color(hex: 0xCECBF6))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Color(hex: 0xAFA9EC, alpha: 0.55), lineWidth: 1))
                            .fixedSize()   // the label gives way, not the tag
                    }
                    Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .lineLimit(1)
                if let r = s.summary, !r.isEmpty {
                    Text(r).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if s.state == .done && s.compactions > 0 {
                    Text(tr("Sugestão: limpe a sessão (/clear) antes do próximo pedido.",
                            "Tip: clear the session (/clear) before your next prompt."))
                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0xCECBF6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let c = s.ctx {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(tr("contexto", "context") + " \(Int(c.rounded()))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(c >= 80 ? Color(hex: 0xAFA9EC) : (c >= 70 ? Color.orange : Color.secondary))
                    ProgressView(value: min(c, 100), total: 100)
                        .tint(c >= 80 ? Color(hex: 0xAFA9EC) : usageColor(c)).frame(width: 60)
                }
            }
        }
    }

    /// Working (or running background tasks) above 80% of its context.
    var isHeavy: Bool { (s.state == .running || s.state == .background) && (s.ctx ?? 0) >= 80 }

    /// How long this session has been waiting for you, or 0 if it isn't waiting.
    var waited: Double { s.state == .awaiting ? Date().timeIntervalSince1970 - s.since : 0 }

    var label: String {
        let now = Date().timeIntervalSince1970
        let minutes = Int((now - s.since) / 60)
        let ago = minutes < 1 ? "agora" : "há \(minutes) min"
        let isJustNow = minutes < 1
        switch s.state {
        case .running:
            let silence = Int((now - s.updated) / 60)
            return silence >= 10
                ? tr("· trabalhando, sem sinal há \(silence) min", "· working, no signal for \(silence) min")
                : tr("· trabalhando, \(ago)", isJustNow ? "· working, just now" : "· working for \(minutes) min")
        case .background: return tr("· em segundo plano: ", "· in background: ") + (s.bg ?? tr("tarefas", "tasks"))
        case .awaiting:
            if waited >= Sounds.burnAfter {
                return tr("· queimou esperando você, há \(minutes) min", "· burnt out waiting for you, \(minutes) min")
            }
            return tr("· precisa de você, \(ago)", isJustNow ? "· needs you, just now" : "· needs you for \(minutes) min")
        case .done: return tr("· terminou, \(ago)", isJustNow ? "· finished just now" : "· finished \(minutes) min ago")
        case .idle: return tr("· parado, \(ago)", isJustNow ? "· idle, just now" : "· idle for \(minutes) min")
        }
    }
}

/// The installed version, at the bottom of the panel. A click asks macOS to open its release page;
/// Psiu itself never goes online.
struct VersionView: View {
    var body: some View {
        HStack {
            Spacer()
            Text("Psiu " + (appVersion ?? "dev"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .onTapGesture {
                    guard let v = appVersion, let url = URL(string: "https://github.com/jaimebrolesi/psiu/releases/tag/v\(v)") else { return }
                    NSWorkspace.shared.open(url)
                }
        }
    }
}

struct ScoreboardView: View {
    let today: Scoreboard
    let weekWaiting: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Hoje", "Today")).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(tr("7 dias: esperou você ", "7 days: waited for you ") + formatDuration(weekWaiting)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                metricTile(tr("Agente trabalhando", "Agent working"), formatDuration(today.working), nil)
                metricTile(tr("Esperando você", "Waiting for you"), formatDuration(today.waiting), Color(hex: 0xFAC775))
                metricTile(tr("Sua resposta média", "Your avg. reply"),
                        today.replyCount > 0 ? formatDuration(today.replyTime / Double(today.replyCount)) : tr("sem dados", "no data"), nil)
            }
            let total = today.working + today.waiting
            if total > 0 {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color(hex: 0x378ADD)).frame(width: geo.size.width * CGFloat(today.working / total))
                        Rectangle().fill(Color(hex: 0xEF9F27))
                    }
                }
                .frame(height: 5)
                .clipShape(Capsule())
            }
            if today.burnt > 0 {
                Text(tr("Psius queimados hoje: \(today.burnt)", "Psius burnt today: \(today.burnt)"))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    func metricTile(_ label: String, _ valueText: String, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Text(valueText).font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(color ?? Color.primary)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }
}
