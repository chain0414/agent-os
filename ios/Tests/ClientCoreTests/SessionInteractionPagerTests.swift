import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct SessionInteractionPagerTests {
    private func notice(_ id: String, type: String = "interaction", session: String = "session", status: String = "open", target: String? = nil, blocking: Bool = true, blockingScope: String = "session") throws -> SessionNoticeModel {
        var raw = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        raw["noticeId"] = id; raw["type"] = type; raw["sessionId"] = session; raw["status"] = status
        raw["blocking"] = blocking ? ["scope": blockingScope, "targetId": session] : NSNull()
        raw["source"] = target.map { ["timelineItemId": $0] } ?? [:]
        raw["context"] = [:]
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

    private func item(_ id: String, user: Bool = false) throws -> V2TimelineItem {
        var raw = try itemObject(id: id, text: "Synthetic transcript body")
        raw["role"] = user ? "user" : "assistant"
        return try decode(raw)
    }

    @Test func onlyCurrentNonblockingTargetsPinWhileHistoricalRequestsStayInDetails() throws {
        let timeline = try [item("old-user", user: true), item("old-request"), item("old-reply"),
                            item("latest-user", user: true), item("latest-request"), item("latest-reply")]
        let current = try notice("current", target: "latest-request", blocking: false)
        let historical = try notice("historical", target: "old-request", blocking: false)
        let unloaded = try notice("unloaded", target: "not-in-window", blocking: false)
        let blocking = try notice("blocking", target: "old-request")
        let unknown = try notice("unknown", blocking: false)
        let pages = SessionInteractionPager.items([current, historical, unloaded, blocking, unknown], sessionID: "session",
            currentTurnItemIDs: SessionInteractionPager.latestTurnItemIDs(in: timeline))
        #expect(pages.map(\.id) == ["current", "blocking", "unknown"])
        #expect(historical.isVisible && unloaded.isVisible)
        #expect(historical.canRespond(fresh: true))
    }

    @Test func nextUserTurnUnpinsOldNonblockingRequestWithoutChangingNoticeStatus() throws {
        let request = try notice("request", target: "request-message", blocking: false)
        let timeline = try [item("user", user: true), item("request-message")]
        let before = SessionInteractionPager.items([request], sessionID: "session",
            currentTurnItemIDs: SessionInteractionPager.latestTurnItemIDs(in: timeline))
        let nextUser = try item("next-user", user: true)
        let after = SessionInteractionPager.items([request], sessionID: "session",
            currentTurnItemIDs: SessionInteractionPager.latestTurnItemIDs(in: timeline + [nextUser]))
        #expect(before.map(\.id) == ["request"])
        #expect(after.isEmpty)
        #expect(request.notice.status == .open && request.isVisible)
    }

    @Test func browsingOlderWindowNeverTreatsItsLastTurnAsCurrent() throws {
        let current = try notice("current", target: "request", blocking: false)
        let unknown = try notice("unknown", blocking: false)
        let blocking = try notice("blocking", target: "request")
        let pages = SessionInteractionPager.items([current, unknown, blocking], sessionID: "session",
            currentTurnItemIDs: ["request"], isLatestWindow: false)
        #expect(pages.map(\.id) == ["blocking"])
        #expect(current.isVisible && unknown.isVisible)
    }

    @Test func pageStartingMidTurnUsesItsLoadedWindowAndKeepsBlockingUnloadedTargets() throws {
        let timeline = try [item("request"), item("reply")]
        #expect(SessionInteractionPager.latestTurnItemIDs(in: timeline) == ["request", "reply"])
        #expect(SessionInteractionPager.latestTurnItemIDs(in: []) == [])
        let current = try notice("current", target: "request", blocking: false)
        let blocking = try notice("blocking", target: "unloaded")
        let pages = SessionInteractionPager.items([current, blocking], sessionID: "session",
            currentTurnItemIDs: SessionInteractionPager.latestTurnItemIDs(in: timeline))
        #expect(pages.map(\.id) == ["current", "blocking"])
    }


    @Test func turnScopedBlockingWithUnknownTargetStaysPinnedWhileBrowsingHistory() throws {
        let turnBlocking = try notice("turn-blocking", target: "historical-request", blockingScope: "turn")
        let pages = SessionInteractionPager.items([turnBlocking], sessionID: "session",
            currentTurnItemIDs: [], isLatestWindow: false)
        #expect(pages.map(\.id) == ["turn-blocking"])
        #expect(!turnBlocking.blocks("session"))
    }


    @Test func steeringUserInputAlsoUnpinsPriorNonblockingQuestion() throws {
        var raw = try itemObject(id: "steering-answer", text: "Synthetic answer")
        raw["role"] = "user"; raw["source"] = ["itemType": "steeringUserMessage"]
        let answer: V2TimelineItem = try decode(raw)
        let timeline = try [item("user", user: true), item("old-request"), answer]
        let request = try notice("old", target: "old-request", blocking: false)
        #expect(SessionInteractionPager.latestTurnItemIDs(in: timeline) == ["steering-answer"])
        #expect(SessionInteractionPager.items([request], sessionID: "session",
            currentTurnItemIDs: SessionInteractionPager.latestTurnItemIDs(in: timeline)).isEmpty)
        #expect(request.isVisible && request.notice.status == .open)
    }

}
