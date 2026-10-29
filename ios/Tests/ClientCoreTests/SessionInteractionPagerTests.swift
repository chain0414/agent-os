import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct SessionInteractionPagerTests {
    private func notice(_ id: String, type: String = "interaction", session: String = "session", status: String = "open") throws -> SessionNoticeModel {
        var raw = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        raw["noticeId"] = id; raw["type"] = type; raw["sessionId"] = session; raw["status"] = status
        return SessionNoticeModel(try decode(raw))
    }

    @Test func selectionSurvivesReorderingAndChoosesAdjacentWhenCurrentDisappears() {
        let pager = SessionInteractionPager()
        pager.synchronize(["one", "two", "three"])
        #expect(pager.selectedID == "one" && pager.pageNumber == 1)
        pager.step(1)
        #expect(pager.selectedID == "two" && pager.pageNumber == 2)
        pager.synchronize(["three", "two", "one"])
        #expect(pager.selectedID == "two")
        pager.synchronize(["three", "one"])
        #expect(pager.selectedID == "one" && pager.pageNumber == 2)
        pager.synchronize(["three"])
        #expect(pager.selectedID == "three" && pager.pageNumber == 1)
        pager.synchronize([])
        #expect(pager.selectedID == nil && pager.pageNumber == 0)
    }

    @Test func steppingAndSelectionStayInsideCurrentPages() {
        let pager = SessionInteractionPager()
        pager.synchronize(["one", "two"])
        pager.step(-1)
        #expect(pager.selectedID == "one")
        pager.step(1); pager.step(1)
        #expect(pager.selectedID == "two")
        pager.select("missing"); pager.select(nil)
        #expect(pager.selectedID == "two")
        pager.synchronize(["two", "three"])
        #expect(pager.selectedID == "two" && pager.pageNumber == 1)
    }

    @Test func onlyOutstandingSessionInteractionsEnterTheSharedPagerAndDraftsStayOwnedByNotice() throws {
        let first = try notice("one"), second = try notice("two")
        first.custom["answer"] = "First draft"; second.custom["answer"] = "Second draft"
        let notification = try notice("notification", type: "notification")
        let resolved = try notice("resolved", status: "resolved")
        let foreign = try notice("foreign", session: "another")
        let pages = SessionInteractionPager.items([first, notification, second, resolved, foreign], sessionID: "session")
        #expect(pages.map(\.id) == ["one", "two"])
        let pager = SessionInteractionPager()
        pager.synchronize(pages.map(\.id)); pager.step(1); pager.step(-1)
        #expect(first.custom["answer"] == "First draft")
        #expect(second.custom["answer"] == "Second draft")
        #expect(pages[0] === first && pages[1] === second)
        #expect(notification.isVisible)
    }
}
