import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct TimelineExecutionSummaryTests {
    private func tool(_ id: String, status: String = "done", timing: [String: Any]? = nil) throws -> ChatTimelineRowModel {
        var item = try itemObject(id: id, text: "")
        item["type"] = "tool"; item["status"] = status
        var content: [String: Any] = ["kind": "tool_call", "name": "test"]
        if let timing { content["turnTiming"] = timing }
        item["content"] = content
        // Deliberately unrelated server persistence times, never execution time.
        item["createdAt"] = "2026-10-29T01:00:00Z"
        item["completedAt"] = "2026-10-29T01:10:00Z"
        return ChatTimelineRowModel(try decode(item))
    }
    private func group(_ timing: [String: Any]? = nil, status: String = "done") throws -> ChatTimelineGroup {
        try #require(TimelineGrouping.groups([tool("a", status: status, timing: timing), tool("b", status: status, timing: timing)], interactionTargets: []).first)
    }
    @Test func usesNativeTurnDurationWithoutAddingParallelTools() throws {
        let value = try group(["durationMs": 29_000, "status": "completed"])
        #expect(value.title.hasPrefix("已完成，用时"))
        #expect(value.title.contains("29"))
        #expect(!value.title.contains("58"))
    }
    @Test func persistenceTimesNeverBecomeExecutionDuration() throws {
        #expect(try group().title == "已完成")
    }
    @Test func nativeTimestampPairIsAcceptedButIncompleteOrInvalidTimeIsNotInvented() throws {
        #expect(try group(["startedAt": 1000, "completedAt": 31_000]).title.contains("30"))
        #expect(try group(["startedAt": 1000]).title == "已完成")
        #expect(try group(["durationMs": -10]).title == "已完成")
        #expect(try group(["startedAt": 31_000, "completedAt": 1000]).title == "已完成")
        #expect(try group(["startedAt": -1000, "completedAt": 1000]).title == "已完成")
    }
    @Test func activeAndFailedStatesNeverClaimCompletion() throws {
        #expect(try group(["durationMs": 29_000, "status": "inProgress"]).title == "进行中")
        #expect(try group(["status": "failed"]).title == "失败")
        #expect(try group(["status": "interrupted"]).title == "已中断")
        #expect(try group(status: "cancelled").title == "已取消")
    }
    @Test func zeroDurationIsDifferentFromMissingDuration() throws {
        #expect(try group(["durationMs": 0]).title.hasPrefix("已完成，用时"))
    }
    @Test func wholeTurnTimeOnlyAppearsOnLastExecutionGroup() throws {
        let timing: [String: Any] = ["durationMs": 29_000, "status": "completed"]
        let middle = ChatTimelineRowModel(try decode(itemObject(id: "commentary", text: "Progress")))
        let groups = try TimelineGrouping.groups([tool("a", timing: timing), tool("b", timing: timing), middle,
                                                 tool("c", timing: timing), tool("d", timing: timing)], interactionTargets: [])
        #expect(groups[0].title == "已完成")
        #expect(groups[2].title.hasPrefix("已完成，用时"))
    }
}
