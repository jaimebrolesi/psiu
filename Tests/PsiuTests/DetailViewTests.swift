import PsiuCore
import Testing
@testable import Psiu

@Suite("Panel")
@MainActor
struct DetailViewTests {
    @Test func listsTheSessionsWaitingForYouFirst() {
        // Newest first, as the repository gives them: the waiting ones are among the oldest.
        let states: [(String, SessionState)] = [("a", .running), ("b", .done), ("c", .running), ("d", .idle),
                                                ("e", .running), ("f", .awaiting), ("g", .awaiting)]
        let sessions = states.enumerated().map { i, s in
            Session(id: s.0, project: s.0, state: s.1, since: Double(100 - i), updated: 100)
        }
        // The longest wait (g) on top, then f, then the others newest first.
        #expect(DetailView.ordered(sessions).map(\.id) == ["g", "f", "a", "b", "c", "d", "e"])
        #expect(DetailView.ordered(Array(sessions.prefix(3))).map(\.id) == ["a", "b", "c"])
    }
}
