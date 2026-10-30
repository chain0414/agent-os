import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct TimelineAutomationTests {
    private let instruction = "<heartbeat>\n<automation_id>drawaa</automation_id>\n<current_time_iso>2026-10-29T03:09:02Z</current_time_iso>\n<instructions>Check progress & remain quiet.</instructions>\n</heartbeat>"
    private let silent = "<heartbeat><automation_id>drawaa</automation_id><decision>DONT_NOTIFY</decision><message>No change.</message></heartbeat>"
    private let notify = "<heartbeat><automation_id>drawaa</automation_id><decision>NOTIFY</decision><message>Completed **delivery**.</message></heartbeat>"

    private func item(_ id: String, role: String = "assistant", text: String, status: String = "done", turn: String? = nil, attachments: Bool = false) throws -> V2TimelineItem {
        var raw = try itemObject(id: id, text: text)
        raw["role"] = role; raw["status"] = status
        raw["turnId"] = turn
        if attachments { raw["content"] = ["text": text, "attachments": [["kind": "file", "fileId": "file"]]] }
        return try decode(raw)
    }

    private func presentation(_ items: [V2TimelineItem]) -> SessionTimelinePresentation {
        let model = SessionTimelinePresentation()
        model.presentOpening(items, pendingMessages: [])
        return model
    }

    @Test func completedControlMessagesPreserveUserAndAssistantBodies() throws {
        let model = presentation(try [item("input", role: "user", text: instruction, turn: "automation"),
                    item("silent", text: silent, turn: "automation"),
                    item("notification", text: notify, turn: "automation")])
        let rows = model.rows
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        #expect(groups.flatMap(\.rows).map(\.id) == ["input", "silent", "notification"])
        #expect(rows[0].text == "Check progress & remain quiet.")
        #expect(rows[1].text == "No change.")
        #expect(rows[2].text == "Completed **delivery**.")
        #expect(rows[0].value.displayText == instruction)
    }

    @Test func quotedMalformedUnknownActiveAndFailedContentStayVisible() throws {
        let messages = ["```xml\n" + silent + "\n```", "Explain " + silent,
                        silent.replacingOccurrences(of: "DONT_NOTIFY", with: "MAYBE"),
                        String(silent.dropLast()), silent.replacingOccurrences(of: "</heartbeat>", with: "<extra>value</extra></heartbeat>"),
                        silent.replacingOccurrences(of: "</heartbeat>", with: "<decision>DONT_NOTIFY</decision></heartbeat>")]
        for (index, text) in messages.enumerated() {
            let value = try item("literal-\(index)", text: text)
            #expect(TimelineAutomationPresentation.classify(value) == nil)
            let row = ChatTimelineRowModel(value)
            #expect(TimelineGrouping.groups([row], interactionTargets: []).count == 1)
            #expect(row.text == text)
        }
        for status in ["running", "failed", "cancelled", "interrupted"] {
            let value = try item(status, text: silent, status: status)
            #expect(TimelineAutomationPresentation.classify(value) == nil)
            let row = ChatTimelineRowModel(value)
            #expect(TimelineGrouping.groups([row], interactionTargets: []).count == 1)
        }
        let value = try item("attached", text: silent, attachments: true)
        #expect(TimelineAutomationPresentation.classify(value) == nil)
        let attached = ChatTimelineRowModel(value)
        #expect(TimelineGrouping.groups([attached], interactionTargets: []).count == 1)
    }

    @Test func projectedInputSeparatesCopyActionsAndNoticeTargetsStayMounted() throws {
        let rows = presentation(try [item("u", role: "user", text: "Question", turn: "one"),
                        item("a", text: "First answer", turn: "one"),
                        item("hidden-input", role: "user", text: instruction, turn: "two"),
                        item("b", text: notify, turn: "two")]).rows
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(actions.count == 2)
        #expect(actions["a"]?.copyText == "First answer")
        #expect(actions["b"]?.copyText == "Completed **delivery**.")
        let protected = TimelineGrouping.groups(rows, interactionTargets: ["hidden-input"])
        #expect(protected.flatMap(\.rows).contains { $0.id == "hidden-input" })
    }

    @Test func finalRevisionReclassifiesAStreamAndRecoveryCanReplaceIt() throws {
        let input = try item("input", role: "user", text: instruction, turn: "auto")
        let model = presentation([input, try item("reply", text: silent, status: "running", turn: "auto")])
        let row = model.rows[1]
        #expect(TimelineGrouping.groups([row], interactionTargets: []).count == 1)
        model.stage([input, try item("reply", text: silent, turn: "auto")], animate: false); model.flush(now: 1)
        #expect(TimelineGrouping.groups([row], interactionTargets: []).count == 1)
        #expect(row.text == "No change.")
        row.flush(try item("reply", text: "Actual failure", status: "failed"), animate: false, now: 2)
        #expect(TimelineGrouping.groups([row], interactionTargets: []).count == 1)
        #expect(row.text == "Actual failure")
    }

    @Test func completeRepliesProjectTheirOwnBodiesAcrossPaginationAndTurnIDs() throws {
        let orphan = presentation([try item("reply", text: silent, turn: "auto")])
        #expect(TimelineGrouping.groups(orphan.rows, interactionTargets: []).count == 1)
        #expect(orphan.rows[0].text == "No change.")
        let conflicting = presentation(try [item("input", role: "user", text: instruction, turn: "auto"),
            item("reply", text: silent.replacingOccurrences(of: "drawaa", with: "other"), turn: "auto")])
        #expect(TimelineGrouping.groups(conflicting.rows, interactionTargets: []).map(\.id) == ["input", "reply"])
        #expect(conflicting.rows[1].text == "No change.")
        let differentTurn = presentation(try [item("input", role: "user", text: instruction, turn: "one"),
            item("reply", text: notify, turn: "two")])
        #expect(differentTurn.rows[1].text == "Completed **delivery**.")
    }

    @Test func legacyAutomationBodiesSurviveMissingTurnIDsAndPagedInstructions() throws {
        let input = try item("input", role: "user", text: instruction)
        let reply = try item("reply", text: silent)
        let notification = try item("notification", text: notify)
        let model = presentation([input, reply, notification])
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).map(\.id) == ["input", "reply", "notification"])
        #expect(model.rows[0].text == "Check progress & remain quiet.")
        #expect(model.rows[1].text == "No change.")
        #expect(model.rows[2].text == "Completed **delivery**.")
        #expect(model.rows[1].value.displayText == silent)
        let protected = TimelineGrouping.groups(model.rows, interactionTargets: ["reply"])
        #expect(protected.flatMap(\.rows).contains { $0.id == "reply" })
        model.showsAutomationRecords = true
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 3)
        model.showsAutomationRecords = false
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).map(\.id) == ["input", "reply", "notification"])
        #expect(model.rows[0].text == "Check progress & remain quiet.")
        #expect(model.rows[1].text == "No change.")
        model.stage([reply, notification], animate: false); model.flush()
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 2)
        #expect(model.rows[1].text == "Completed **delivery**.")
    }

    @Test func completeReplyBodyDoesNotDependOnThePreviousUserEnvelope() throws {
        let input = try item("input", role: "user", text: instruction)
        let boundaries = try [
            item("ordinary", role: "user", text: "Explain this XML"),
            item("unknown", role: "user", text: instruction.replacingOccurrences(of: "</heartbeat>", with: "<unknown>x</unknown></heartbeat>")),
            item("incomplete", role: "user", text: String(instruction.dropLast())),
            item("failed", role: "user", text: instruction, status: "failed"),
            item("running", role: "user", text: instruction, status: "running"),
            item("attached", role: "user", text: instruction, attachments: true),
            item("explicit", role: "user", text: instruction, turn: "explicit"),
            item("different", role: "user", text: instruction.replacingOccurrences(of: "drawaa", with: "other")),
        ]
        for boundary in boundaries {
            let model = presentation([input, boundary, try item("reply", text: silent)])
            #expect(!model.rows[2].structure.isAutomationHidden)
            #expect(model.rows[2].text == "No change.")
        }
        let orphan = presentation([try item("reply", text: silent)])
        #expect(!orphan.rows[0].structure.isAutomationHidden)
    }

    @Test func bodyProjectionPreservesMessagesWithDifferentOrAmbiguousTurnIDs() throws {
        for (inputTurn, replyTurn) in [(nil, "reply"), ("input", nil), ("input", "reply")] as [(String?, String?)] {
            let model = presentation(try [item("input", role: "user", text: instruction, turn: inputTurn),
                item("reply", text: silent, turn: replyTurn)])
            #expect(!model.rows[1].structure.isAutomationHidden)
            #expect(model.rows[1].text == "No change.")
        }
        let ambiguous = presentation(try [item("one", role: "user", text: instruction, turn: "same"),
            item("two", role: "user", text: instruction.replacingOccurrences(of: "drawaa", with: "other"), turn: "same"),
            item("reply", text: silent, turn: "same")])
        #expect(!ambiguous.rows[2].structure.isAutomationHidden)
    }

    @Test func bodyProjectionSurvivesExplicitNonUserTurnBoundaries() throws {
        let input = try item("input", role: "user", text: instruction)
        let assistant = try item("explicit-assistant", text: "Another turn", turn: "explicit")
        var toolRaw = try itemObject(id: "explicit-tool")
        toolRaw["type"] = "tool"; toolRaw["turnId"] = "explicit"
        toolRaw["content"] = ["kind": "command", "command": "build"]
        let tool: V2TimelineItem = try decode(toolRaw)
        for boundary in [assistant, tool] {
            let model = presentation([input, boundary, try item("reply", text: silent)])
            #expect(!model.rows[2].structure.isAutomationHidden)
            #expect(model.rows[2].text == "No change.")
        }
    }

    @Test func rawRecordToggleRestoresWrappersWithoutLosingBodiesOrRawExport() throws {
        let input = try item("input", role: "user", text: instruction, turn: "auto")
        let reply = try item("reply", text: silent, turn: "auto")
        let model = presentation([input, reply])
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 2)
        #expect(model.rows[0].text == "Check progress & remain quiet.")
        #expect(model.rows[1].text == "No change.")
        let retained = model.rows[0]
        model.showsAutomationRecords = true
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 2)
        #expect(model.rows[0].text == instruction)
        #expect(model.rows[1].text == silent)
        model.stage([input, reply], animate: false); model.flush()
        #expect(model.rows[0] === retained)
        model.showsAutomationRecords = false
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 2)
        #expect(model.rows[0].text == "Check progress & remain quiet.")
        #expect(model.rows[1].text == "No change.")
        #expect(model.rows[0].value == input && model.rows[1].value == reply)
        model.stage([reply], animate: false); model.flush()
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 1)
    }

    @Test func projectedFinalInputClosesPreviousTurnEvenWhileLatestIsRunning() throws {
        let rows = presentation(try [item("u", role: "user", text: "Question"), item("a", text: "Answer"),
            item("hidden", role: "user", text: instruction)]).rows
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: true)
        #expect(actions["a"]?.copyText == "Answer")
    }

    @Test func toolGroupsNeverMergeAcrossProjectedInstructionsAndFailuresRemainVisible() throws {
        func tool(_ id: String, turn: String, status: String = "done") throws -> V2TimelineItem {
            var raw = try itemObject(id: id)
            raw["type"] = "tool"; raw["turnId"] = turn; raw["status"] = status
            raw["content"] = ["kind": "command", "command": "build"]
            return try decode(raw)
        }
        let model = presentation(try [tool("one", turn: "first"), tool("two", turn: "first"),
            item("hidden", role: "user", text: instruction, turn: "second"),
            tool("three", turn: "second", status: "failed"), tool("four", turn: "second"),
            item("reply", text: silent, turn: "second")])
        let groups = TimelineGrouping.groups(model.rows, interactionTargets: [])
        try #require(groups.count == 4)
        #expect(groups[0].rows.map(\.id) == ["one", "two"])
        #expect(groups[1].rows.map(\.id) == ["hidden"])
        #expect(groups[2].rows.map(\.id) == ["three", "four"])
        #expect(groups[3].rows.map(\.id) == ["reply"])
        #expect(groups[2].rows[0].value.status == .failed)
        #expect(groups[1].startsTurn)
    }
    @Test func legacyScheduledTurnsKeepBothBodiesAroundOneCollapsedToolGroupPerTurn() throws {
        let userBody = "2026-10-28T09:36 UTC监控仅收到芽芽dev已完成的最终体验回执，已核 idle/completed，无新需求/新交付/阻塞。"
        let answerBody = "无新增需求、交付或阻塞；运行窗口保持关闭，未操作设备与存档。"
        let scheduledInput = instruction.replacingOccurrences(of: "Check progress & remain quiet.", with: userBody)
        let scheduledReply = silent.replacingOccurrences(of: "No change.", with: answerBody)
        func tool(_ id: String) throws -> V2TimelineItem {
            var raw = try itemObject(id: id)
            raw["type"] = "tool"; raw["role"] = "assistant"
            raw["content"] = ["kind": "command", "command": "synthetic-read-only-check"]
            return try decode(raw)
        }
        let input = try item("first-input", role: "user", text: scheduledInput)
        let reply = try item("first-reply", text: scheduledReply)
        let model = presentation(try [input, tool("first-tool-a"), tool("first-tool-b"), reply,
            item("second-input", role: "user", text: scheduledInput), tool("second-tool-a"), tool("second-tool-b"),
            item("second-reply", text: scheduledReply)])
        let groups = TimelineGrouping.groups(model.rows, interactionTargets: [])
        #expect(groups.map(\.id) == ["first-input", "first-tool-a", "first-reply", "second-input", "second-tool-a", "second-reply"])
        try #require(groups.count == 6)
        #expect(groups[1].kind == .tools && groups[1].rows.count == 2)
        #expect(groups[4].kind == .tools && groups[4].rows.count == 2)
        let disclosures = TimelineDisclosureState()
        #expect(!disclosures.isExpanded(groups[1].id) && !disclosures.isExpanded(groups[4].id))
        #expect(model.rows[0].text == userBody && model.rows[4].text == userBody)
        #expect(model.rows[3].text == answerBody && model.rows[7].text == answerBody)
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: false)
        #expect(actions.count == 2)
        #expect(actions["first-reply"]?.copyText == answerBody)
        #expect(actions["second-reply"]?.copyText == answerBody)
        #expect(model.rows[0].value == input && model.rows[3].value == reply)
        model.showsAutomationRecords = true
        #expect(model.rows[0].text == scheduledInput && model.rows[3].text == scheduledReply)
        model.showsAutomationRecords = false
        #expect(model.rows[0].text == userBody && model.rows[3].text == answerBody)
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).map(\.id) == groups.map(\.id))
    }

}
