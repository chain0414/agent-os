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

    @Test func completedControlMessagesHideButNotificationShowsItsBody() throws {
        let model = presentation(try [item("input", role: "user", text: instruction, turn: "automation"),
                    item("silent", text: silent, turn: "automation"),
                    item("notification", text: notify, turn: "automation")])
        let rows = model.rows
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        #expect(groups.flatMap(\.rows).map(\.id) == ["notification"])
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

    @Test func hiddenInputStillSeparatesCopyActionsAndNoticeTargetsStayMounted() throws {
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
        #expect(TimelineGrouping.groups([row], interactionTargets: []).isEmpty)
        row.flush(try item("reply", text: "Actual failure", status: "failed"), animate: false, now: 2)
        #expect(TimelineGrouping.groups([row], interactionTargets: []).count == 1)
        #expect(row.text == "Actual failure")
    }

    @Test func missingOrConflictingInstructionKeepsTheRawResult() throws {
        let orphan = presentation([try item("reply", text: silent, turn: "auto")])
        #expect(TimelineGrouping.groups(orphan.rows, interactionTargets: []).count == 1)
        #expect(orphan.rows[0].text == silent)
        let conflicting = presentation(try [item("input", role: "user", text: instruction, turn: "auto"),
            item("reply", text: silent.replacingOccurrences(of: "drawaa", with: "other"), turn: "auto")])
        #expect(TimelineGrouping.groups(conflicting.rows, interactionTargets: []).map(\.id) == ["reply"])
        let differentTurn = presentation(try [item("input", role: "user", text: instruction, turn: "one"),
            item("reply", text: notify, turn: "two")])
        #expect(differentTurn.rows[1].text == notify)
    }

    @Test func rawRecordToggleRestoresAndRehidesWithoutLosingRowsOrRawExport() throws {
        let input = try item("input", role: "user", text: instruction, turn: "auto")
        let reply = try item("reply", text: silent, turn: "auto")
        let model = presentation([input, reply])
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).isEmpty)
        let retained = model.rows[0]
        model.showsAutomationRecords = true
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 2)
        #expect(model.rows[1].text == silent)
        model.stage([input, reply], animate: false); model.flush()
        #expect(model.rows[0] === retained)
        model.showsAutomationRecords = false
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).isEmpty)
        #expect(model.rows[0].value == input && model.rows[1].value == reply)
        model.stage([reply], animate: false); model.flush()
        #expect(TimelineGrouping.groups(model.rows, interactionTargets: []).count == 1)
    }

    @Test func hiddenFinalInputClosesPreviousTurnEvenWhileLatestIsRunning() throws {
        let rows = presentation(try [item("u", role: "user", text: "Question"), item("a", text: "Answer"),
            item("hidden", role: "user", text: instruction)]).rows
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: true)
        #expect(actions["a"]?.copyText == "Answer")
    }

    @Test func toolGroupsNeverMergeAcrossHiddenInstructionsAndFailuresRemainVisible() throws {
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
        #expect(groups.count == 2)
        #expect(groups[0].rows.map(\.id) == ["one", "two"])
        #expect(groups[1].rows.map(\.id) == ["three", "four"])
        #expect(groups[1].rows[0].value.status == .failed)
        #expect(groups[0].endsAtHiddenTurnBoundary && groups[1].startsTurn)
    }
}
