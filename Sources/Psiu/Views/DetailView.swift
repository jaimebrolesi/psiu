import AppKit
import PsiuCore
import SwiftUI

struct DetailView: View {
    let store: Store
    var onOpen: (Session) -> Void = { _ in }

    /// The sessions in the order the panel lists them: those waiting for you first, the longest wait on top,
    /// so none hides at the bottom of the list; then the others, newest first.
    static func ordered(_ sessions: [Session]) -> [Session] {
        let waiting = sessions.filter { $0.state == .awaiting }.sorted { $0.since < $1.since }
        return waiting + sessions.filter { $0.state != .awaiting }
    }

    /// The sessions card is as tall as this many sessions; the others scroll under a fade.
    static let visibleSessions = 4
    static let fade: CGFloat = 22

    /// Limits, sessions and today, each in its card; the cards share the tallest one's height.
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            card { limits }.frame(width: 180)
            card { scrollingSessions }
            card {
                VStack(alignment: .leading, spacing: 8) {
                    ScoreboardView(today: store.today, weekWaiting: store.weekWaiting)
                    Spacer(minLength: 0)
                    VersionView()
                }
            }
            .frame(width: 170)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 12)
    }

    func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.06)))
    }

    var limits: some View {
        VStack(alignment: .leading, spacing: 12) {
            LimitView(title: tr("Sessão de 5 horas", "5-hour session"), usageWindow: store.fiveHour, format: "HH:mm",
                       overflow: store.forecast, headroom: store.forecastHeadroom)
            LimitView(title: tr("Semana", "Week"), usageWindow: store.week, format: "EEE HH:mm")
        }
    }

    /// Every session, in a list as tall as the first four: the rest scroll, and a fade at the bottom says there's more.
    @ViewBuilder var scrollingSessions: some View {
        let all = Self.ordered(store.sessions)
        if all.count <= Self.visibleSessions {
            sessions
        } else {
            CappedHeight(extra: Self.fade) {
                ScrollView {
                    rows(all)
                        .padding(.bottom, Self.fade)   // at the end, the last one clears the fade
                }
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
                    }
                }
                // Only measured: the first four show whole, and the fifth starts under the fade.
                rows(Array(all.prefix(Self.visibleSessions))).hidden()
            }
        }
    }

    func rows(_ list: [Session]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(list) { s in
                SessionView(s: s)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpen(s) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var sessions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.sessions.isEmpty {
                Text(tr("Nenhuma sessão do Claude Code aberta.", "No Claude Code sessions open."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                rows(Self.ordered(store.sessions))
            }
        }
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
                            Rectangle().fill(Palette.forecastOverflow)
                                .frame(width: max(0, w - used)).offset(x: used)
                        }
                        Capsule().fill(usageColor(j.pct)).frame(width: used)
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 5)
                // In a narrow card the forecast goes under the reset time.
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(resetText(j)).font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        forecast
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(resetText(j)).font(.system(size: 10)).foregroundStyle(.secondary)
                        forecast
                    }
                }
            } else {
                Text(tr("Aparece depois da primeira resposta numa sessão.", "Shows up after the first reply in a session."))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var forecast: some View {
        if let e = overflow {
            Text(tr("No ritmo atual, acaba às ", "At this pace, runs out at ") + shortTime(e))
                .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.warning)
        } else if headroom {
            Text(tr("No ritmo atual, dá folga", "At this pace, plenty left")).font(.system(size: 10)).foregroundStyle(.secondary)
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
            Circle().fill(waited >= Sounds.panicAfter ? Palette.panic
                          : isHeavy ? Palette.tired : stateColor(s.state))
                .frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(s.project).font(.system(size: 12, weight: .semibold))
                    Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
                    if s.compactions > 0 {
                        Text(tr("compactada \(s.compactions)x", "compacted \(s.compactions)x"))
                            .font(.system(size: 10)).foregroundStyle(Palette.tiredText)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Capsule().stroke(Palette.tiredOutline, lineWidth: 1))
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
                        .font(.system(size: 10)).foregroundStyle(Palette.tiredText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let c = s.ctx {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(tr("contexto", "context") + " \(Int(c.rounded()))%")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(c >= 80 ? Palette.tired : (c >= 70 ? Color.orange : Color.secondary))
                    ProgressView(value: min(c, 100), total: 100)
                        .tint(c >= 80 ? Palette.tired : usageColor(c)).frame(width: 60)
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

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

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

    /// In its narrow card: the week under the title and the tiles one above the other.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr("Hoje", "Today")).font(.system(size: 12, weight: .medium))
                Text(tr("7 dias: esperou você ", "7 days: waited for you ") + formatDuration(weekWaiting)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(spacing: 6) {
                metricTile(tr("Agente trabalhando", "Agent working"), formatDuration(today.working), nil)
                metricTile(tr("Esperando você", "Waiting for you"), formatDuration(today.waiting), Palette.warning)
                metricTile(tr("Sua resposta média", "Your avg. reply"),
                        today.replyCount > 0 ? formatDuration(today.replyTime / Double(today.replyCount)) : tr("sem dados", "no data"), nil)
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

/// As tall as its first view, but no taller than its second one (which is only measured) plus `extra`.
struct CappedHeight: Layout {
    var extra: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let free = ProposedViewSize(width: proposal.width, height: nil)
        let content = subviews[0].sizeThatFits(free), cap = subviews[1].sizeThatFits(free)
        return CGSize(width: proposal.width ?? content.width, height: min(content.height, cap.height + extra))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
