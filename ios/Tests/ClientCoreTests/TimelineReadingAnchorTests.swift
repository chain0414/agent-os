import Foundation
import Testing
@testable import ClientCore

@Suite struct TimelineReadingAnchorTests {
    @Test func recreatingChatForSameSessionRetainsTimelineAndReadingIntent() {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let session = repo.session(id: "session")
        let first = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        let second = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        #expect(first.timeline === second.timeline)
        session.readingAnchor.measure(id: "row", y: 0, height: 300, width: 350, isParagraph: false)
        session.readingAnchor.capture(top: 150, width: 350, following: false)
        #expect(second.session.readingAnchor.anchor?.fraction == 0.5)
    }
    @Test func paragraphAnchorSurvivesWidthChangesAndDoesNotUseOldPixels() throws {
        let state = TimelineReadingAnchorStore()
        state.measure(id: "row", y: 100, height: 1000, width: 350, isParagraph: false)
        state.measure(id: "row:block:3", y: 400, height: 200, width: 350, isParagraph: true)
        state.capture(top: 450, width: 350, following: false)
        let anchor = try #require(state.anchor)
        #expect(anchor.id == "row:block:3")
        #expect(anchor.fraction == 0.25)
        #expect(state.target(for: anchor, width: 700) == nil)
        state.measure(id: anchor.id, y: 200, height: 100, width: 700, isParagraph: true)
        #expect(state.target(for: anchor, width: 700) == 225)
    }

    @Test func bottomFollowingAndUserReadingAreIndependentOfGeometry() {
        let state = TimelineReadingAnchorStore()
        state.measure(id: "row", y: 0, height: 200, width: 350, isParagraph: false)
        state.capture(top: 30, width: 350, following: false)
        #expect(state.anchor?.id == "row" && !state.followsBottom)
        state.capture(top: 100, width: 350, following: true)
        #expect(state.followsBottom && state.anchor == nil)
    }

    @Test func staleWidthsAndRemovedRowsCannotReplaceCurrentAnchor() {
        let state = TimelineReadingAnchorStore()
        state.measure(id: "old", y: 0, height: 500, width: 350, isParagraph: false)
        state.capture(top: 100, width: 700, following: false)
        #expect(state.anchor == nil)
        state.measure(id: "new", y: 0, height: 500, width: 700, isParagraph: false)
        state.capture(top: 100, width: 700, following: false)
        state.retain(rowIDs: ["other"])
        #expect(state.anchor == nil)
    }
}
