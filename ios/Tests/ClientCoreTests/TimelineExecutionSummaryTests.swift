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
    private func message(_ id: String, role: String = "assistant", phase: String? = nil) throws -> ChatTimelineRowModel {
        var item = try itemObject(id: id, text: id)
        item["role"] = role; item["status"] = "done"; item.removeValue(forKey: "turnId")
        if let phase { item["content"] = ["text": id, "phase": phase] }
        return ChatTimelineRowModel(try decode(item))
    }

    @Test func completedTurnsFoldProgressReasoningAndToolsBeforeFinalReply() throws {
        let timing: [String: Any] = ["durationMs": 67_620, "status": "completed"]
        var reason = try itemObject(id: "reason", text: "")
        reason["type"] = "system"; reason["content"] = ["kind": "reasoning"]
        let rows = try [message("ask", role: "user"), message("progress"), ChatTimelineRowModel(decode(reason)),
                        tool("command", timing: timing), message("update"), tool("search", timing: timing),
                        message("final"), message("next", role: "user"), tool("singleTool", timing: timing),
                        message("dshFinal")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [], latestTurnIsComplete: true)
        #expect(groups.map(\.id) == ["ask", "progress", "final", "next", "singleTool", "dshFinal"])
        #expect(groups.filter { $0.kind == .completedTurn }.map { $0.rows.map(\.id) }
            == [["progress", "reason", "command", "update", "search"], ["singleTool"]])
        #expect(groups.filter { $0.kind == .completedTurn }.map(\.executionDuration) == [67.62, 67.62])
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(actions["final"]?.copyText == "final")
        #expect(actions["dshFinal"]?.copyText == "dshFinal")
    }

    @Test func historyWithoutTimingStillFoldsButActiveAndProtectedRowsRemainVisible() throws {
        let rows = try [message("ask", role: "user"), message("progress"), tool("command"), message("final")]
        let active = TimelineGrouping.groups(rows, interactionTargets: [], latestTurnIsComplete: false)
        #expect(active.map(\.id) == ["ask", "progress", "command", "final"])
        let settled = TimelineGrouping.groups(rows, interactionTargets: [], latestTurnIsComplete: true)
        #expect(settled.map(\.id) == ["ask", "progress", "final"])
        #expect(settled[1].executionDuration == nil)
        let protected = TimelineGrouping.groups(rows, interactionTargets: ["command"], latestTurnIsComplete: true)
        #expect(protected.first { $0.id == "command" }?.kind == .single)
        let withoutFinal = TimelineGrouping.groups(Array(rows.dropLast()), interactionTargets: [], latestTurnIsComplete: true)
        #expect(!withoutFinal.contains { $0.kind == .completedTurn })
    }

    @Test func firstStreamingToolIsFoldedWhileProgressAndApprovalsStayVisible() throws {
        let rows = try [message("ask", role: "user"), message("progress", phase: "commentary"),
                        tool("command", status: "running"), tool("approval")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: ["approval"], latestTurnIsComplete: false)
        #expect(groups.map(\.id) == ["ask", "progress", "command", "approval"])
        #expect(groups.map(\.kind) == [.single, .single, .tools, .single])
        #expect(!TimelineDisclosureState().isExpanded("group:command"))
    }

    @Test func finishedCommentaryIsNotMistakenForTheFinalResponse() throws {
        let rows = try [message("ask", role: "user"), tool("command"), message("update", phase: "commentary")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [], latestTurnIsComplete: true)
        #expect(groups.map(\.id) == ["ask", "command", "update"])
        #expect(!groups.contains { $0.kind == .completedTurn })
    }

    @Test func foldingKeepsAnInteractionTargetVisibleAndInOrder() throws {
        let rows = try [message("ask", role: "user"), tool("before"), tool("approval"),
                        tool("after"), message("final")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: ["approval"], latestTurnIsComplete: true)
        #expect(groups.map(\.id) == ["ask", "before", "approval", "after", "final"])
        #expect(groups.map(\.kind) == [.single, .completedTurn, .single, .completedTurn, .single])
        let disclosures = TimelineDisclosureState()
        #expect(!disclosures.isExpanded("turn:before"))
        #expect(!disclosures.isExpanded("turn:after"))
    }

}
