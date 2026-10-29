import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct AutomationInstructionDisclosureTests {
    private func item(time: String? = "2026-10-29T03:09:02Z", body: String = "Check progress & keep the useful result.") throws -> V2TimelineItem {
        var value = try itemObject(id: "automation-input", text: "<heartbeat><automation_id>test</automation_id>\(time.map { "<current_time_iso>\($0)</current_time_iso>" } ?? "")<instructions>\(body)</instructions></heartbeat>")
        value["role"] = "user"; value["status"] = "done"
        return try decode(value)
    }
    @Test func completeInstructionIsAvailableToDisclosureWithoutControlTags() throws {
        let row = ChatTimelineRowModel(try item())
        let input = try #require(row.automationInstruction)
        #expect(input.text == "Check progress & keep the useful result.")
        #expect(input.timestamp == V2Timestamp.date("2026-10-29T03:09:02Z"))
        #expect(row.text == input.text)
        #expect(row.value.displayText.contains("<heartbeat>"))
    }
    @Test func rawToggleRestoresOriginalMessageInsteadOfWrappingItAgain() throws {
        let row = ChatTimelineRowModel(try item())
        row.showAutomationRecords(true)
        #expect(row.automationInstruction == nil)
        #expect(row.text == row.value.displayText)
        row.showAutomationRecords(false)
        #expect(row.automationInstruction != nil)
    }
    @Test func missingOrInvalidNativeTimeDoesNotUseServerIngestionTime() throws {
        #expect(try ChatTimelineRowModel(item(time: nil)).automationInstruction?.timestamp == nil)
        #expect(try ChatTimelineRowModel(item(time: "invalid")).automationInstruction?.timestamp == nil)
    }
    @Test func ordinaryUserAndAssistantResultStayOutsideInstructionDisclosure() throws {
        var raw = try itemObject(id: "ordinary", text: "Please inspect <heartbeat> as text.")
        raw["role"] = "user"
        #expect(ChatTimelineRowModel(try decode(raw)).automationInstruction == nil)
        let reply = ChatTimelineRowModel(try decode(itemObject(id: "answer", text: "<heartbeat><automation_id>test</automation_id><decision>DONT_NOTIFY</decision><message>No change.</message></heartbeat>")))
        #expect(reply.automationInstruction == nil)
        #expect(reply.text == "No change.")
    }
    @Test func explicitNativeScheduleMarkerPreservesBodyAndNativeTime() throws {
        var raw = try itemObject(id: "native-schedule", text: "Run the scheduled daily report.")
        raw["role"] = "user"
        raw["content"] = ["kind": "markdown", "text": "Run the scheduled daily report.",
                          "automation": ["kind": "schedule", "timestampMs": 1_000]]
        let row = ChatTimelineRowModel(try decode(raw))
        #expect(row.automationInstruction?.text == "Run the scheduled daily report.")
        #expect(row.automationInstruction?.timestamp == Date(timeIntervalSince1970: 1))
        row.showAutomationRecords(true)
        #expect(row.automationInstruction == nil)
        #expect(row.text == row.value.displayText)
    }

}
