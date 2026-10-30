import Foundation
import Testing
import Observation
import Synchronization
@testable import ClientCore

@Suite @MainActor struct TimelineRenderEntryTests {
    @Test func shortStreamTextChangesDoNotInvalidateRootEntryProjection() throws {
        let row = ChatTimelineRowModel(try decode(itemObject(id: "short", text: "Hello")))
        let changed = Mutex(false)
        withObservationTracking {
            _ = TimelineRenderEntry.build(groups: TimelineGrouping.groups([row], interactionTargets: []))
        } onChange: { changed.withLock { $0 = true } }
        row.flush(try decode(itemObject(id: "short", text: "Hello world")), animate: false, now: 1)
        #expect(!changed.withLock { $0 })
    }
    @Test func longReplyExposesUniqueParagraphTargetsAndOneMessageTail() throws {
        let row = ChatTimelineRowModel(try decode(itemObject(id: "long", text: String(repeating: "a", count: 20_000))))
        row.markdown.publish(blocks: [MarkdownBlockSnapshot(id: 0, content: AttributedString("first")),
                                      MarkdownBlockSnapshot(id: 1, content: AttributedString("second"))],
                             state: MarkdownParseState(), deadlines: [:])
        let entries = TimelineRenderEntry.build(groups: TimelineGrouping.groups([row], interactionTargets: []))
        #expect(entries.map(\.id) == ["long:block:0", "long:block:1", "long:message-tail"])
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.filter { if case .messageTail = $0.content { true } else { false } }.count == 1)
        #expect(entries.allSatisfy { $0.group.rows.first === row })
    }

    @Test func shortAndUserMessagesKeepTheirExistingTargets() throws {
        let short = ChatTimelineRowModel(try decode(itemObject(id: "short", text: "Reply")))
        var raw = try itemObject(id: "user", text: String(repeating: "a", count: 20_000))
        raw["role"] = "user"
        let user = ChatTimelineRowModel(try decode(raw))
        let entries = TimelineRenderEntry.build(groups: TimelineGrouping.groups([user, short], interactionTargets: []))
        #expect(entries.map(\.id) == ["user", "short"])
    }

    @Test func authoritativeReplacementDropsPreviouslyParsedLongReply() throws {
        let row = ChatTimelineRowModel(try decode(itemObject(id: "long", text: String(repeating: "a", count: 20_000))))
        row.markdown.publish(blocks: [MarkdownBlockSnapshot(id: 0, content: AttributedString("old"))],
                             state: MarkdownParseState(), deadlines: [:])
        var replacement = try itemObject(id: "long", text: "New answer")
        replacement["revision"] = 2
        row.flush(try decode(replacement), animate: false, now: 0)
        #expect(row.markdown.blocks.isEmpty)
        #expect(!row.usesBlockTimeline)
    }

    @Test func loadingHistoryPreservesAMountedParagraphWithoutRequiringTheMessagesFirstBlock() throws {
        let row = ChatTimelineRowModel(try decode(itemObject(id: "long", text: String(repeating: "a", count: 20_000))))
        row.markdown.publish(blocks: (0..<30).map { MarkdownBlockSnapshot(id: $0, content: AttributedString("paragraph")) },
                             state: MarkdownParseState(), deadlines: [:])
        let entries = TimelineRenderEntry.build(groups: TimelineGrouping.groups([row], interactionTargets: []))
        let store = TimelineReadingAnchorStore()
        store.measure(id: "long:block:20", y: 5000, height: 500, width: 350, isParagraph: true)
        store.capture(top: 5100, width: 350, following: false)
        let origin = try #require(store.historyLayout(firstRowID: "long", entries: entries, top: 5100, width: 350))
        #expect(origin.anchorRowID == "long:block:20" && origin.y == 5000)
        var position = TimelineHistoryPosition(id: 1, layout: origin, offsetY: 5050, topInset: 50)
        position.receivedPage(firstRowID: "older")
        #expect(position.laidOut(.init(firstRowID: "older", anchorRowID: "long:block:20", edge: .top, y: 5800), generation: 1) == 5850)
        #expect(position.isReadyToFinish)
        store.retain(rowIDs: ["long"])
        #expect(store.anchor?.id == "long:block:20")
    }

    @Test func emptyParseStillHasOneTailAndRetainsItsReadingTarget() throws {
        let row = ChatTimelineRowModel(try decode(itemObject(id: "long", text: String(repeating: "a", count: 20_000))))
        let entries = TimelineRenderEntry.build(groups: TimelineGrouping.groups([row], interactionTargets: []))
        #expect(entries.map(\.id) == ["long:message-tail"])
        let store = TimelineReadingAnchorStore()
        store.measure(id: entries[0].id, y: 100, height: 50, width: 350, isParagraph: false)
        store.capture(top: 110, width: 350, following: false)
        store.retain(rowIDs: ["long"])
        #expect(store.anchor?.id == entries[0].id)
    }
}
