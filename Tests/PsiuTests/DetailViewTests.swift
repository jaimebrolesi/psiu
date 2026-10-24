import PsiuCore
import Testing
@testable import Psiu

@Suite("Panel")
struct DetailViewTests {
    @Test func countsTheSessionsBeyondTheFirstFive() {
        #expect(DetailView.moreSessionsText(0) == nil)
        #expect(DetailView.moreSessionsText(5) == nil)
        #expect(DetailView.moreSessionsText(6) == tr("+1 sessão", "+1 more session"))
        #expect(DetailView.moreSessionsText(9) == tr("+4 sessões", "+4 more sessions"))
    }
}
