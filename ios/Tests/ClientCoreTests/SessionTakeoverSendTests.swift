import Foundation
import Testing
@testable import ClientCore

@Suite @MainActor struct SessionTakeoverSendTests {
    @Test func sendTakesOverThenUsesFreshPermissionAndSubmitsFinalDraftOnce() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        try await harness.start()
        #expect(!harness.session.canSend && harness.model.canRequestSend)
        await harness.model.sendFromComposer(harness.session.composer.text)
        #expect(harness.http.count("takeover") == 1 && harness.http.count("messages") == 1)
        #expect(harness.session.metadata?.takeover == true && harness.session.runtime.isFresh)
        #expect(harness.session.pendingMessages.first?.content == "最终转写：请检查登录页。")
        #expect(harness.session.composer.text.isEmpty && harness.model.error == nil)
    }

    @Test(arguments: ["rejected", "uncertain"])
    func takeoverFailurePreservesDraftAndDoesNotSend(kind: String) async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.takeoverFailure = kind == "rejected"
            ? HTTPError.server(statusCode: 403, message: "Synthetic rejection") : URLError(.timedOut)
        try await harness.start()
        let original = harness.session.composer.text
        await harness.model.sendFromComposer(original)
        #expect(harness.http.count("takeover") == 1 && harness.http.count("messages") == 0)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
        #expect(harness.model.takeoverUncertain == (kind == "uncertain"))
        if kind == "uncertain" {
            await harness.model.sendFromComposer(original)
            #expect(!harness.model.canRequestSend && harness.http.count("takeover") == 1)
        }
    }

    @Test func confirmedTakeoverWithFailedFollowupReadDoesNotSendOrRepeatTakeover() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.failFollowupRead = true
        try await harness.start()
        let original = harness.session.composer.text
        await harness.model.sendFromComposer(original)
        #expect(harness.session.metadata?.takeover == true && !harness.session.runtime.isFresh)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
        await harness.model.sendFromComposer(original)
        #expect(harness.http.count("takeover") == 1 && harness.http.count("messages") == 0)
    }

    @Test func uncertainTakeoverCannotReuseAnOlderAllowedSnapshot() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.takenOver = true
        try await harness.start()
        harness.takeoverFailure = URLError(.timedOut)
        #expect(!(await harness.model.setTakeover(false)))
        #expect(harness.model.takeoverUncertain && harness.session.canSend)
        #expect(!harness.model.canRequestSend)
        let original = harness.session.composer.text
        await harness.model.sendFromComposer(original)
        #expect(harness.http.count("takeover") == 1 && harness.http.count("messages") == 0)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
    }

    @Test func anotherActionKeepsAnAlreadyWritableSessionSendUnavailable() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.takenOver = true
        try await harness.start()
        harness.session.isPerformingAction = true
        #expect(harness.session.canSend && !harness.model.canRequestSend)
        let original = harness.session.composer.text
        await harness.model.sendFromComposer(original)
        #expect(harness.http.count("takeover") == 0 && harness.http.count("messages") == 0)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
    }

    @Test func runtimeDenialAfterTakeoverStillPreventsSending() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.allowedAfterTakeover = false
        try await harness.start()
        let original = harness.session.composer.text
        await harness.model.sendFromComposer(original)
        #expect(harness.session.runtime.isFresh && !harness.session.canSend)
        #expect(harness.http.count("takeover") == 1 && harness.http.count("messages") == 0)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
    }

    @Test func noticeArrivingDuringTakeoverStillBlocksThePendingSend() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        let gate = TestGate(); harness.takeoverGate = gate
        try await harness.start()
        let original = harness.session.composer.text
        let submission = Task { await harness.model.sendFromComposer(original) }
        try await eventually { harness.http.count("takeover") == 1 }
        harness.blockingNotice = true
        gate.release(); await submission.value
        #expect(harness.session.runtime.isFresh && !harness.session.canSend)
        #expect(harness.http.count("messages") == 0 && harness.model.error != nil)
        #expect(harness.session.composer.text == original)
    }

    @Test(arguments: ["offline", "notice", "other-denial", "unsupported", "unavailable", "stale", "busy"])
    func unrelatedRestrictionsNeverAuthorizeTakeoverOrSend(restriction: String) async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        if restriction == "notice" { harness.blockingNotice = true }
        if restriction == "other-denial" { harness.denialReason = "permission_denied" }
        if restriction == "unsupported" { harness.supported = false }
        if restriction == "unavailable" { harness.available = false }
        try await harness.start()
        if restriction == "offline" { harness.repo.updateConnectivity(.init(availability: .offline)) }
        if restriction == "stale" { harness.repo.suspend() }
        if restriction == "busy" { harness.session.isPerformingAction = true }
        let original = harness.session.composer.text
        #expect(!harness.model.canRequestSend)
        await harness.model.sendFromComposer(original)
        #expect(harness.http.count("takeover") == 0 && harness.http.count("messages") == 0)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
    }

    @Test func cancelledSubmissionCannotSendAfterLateTakeoverResponse() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        let gate = TestGate(); harness.takeoverGate = gate
        try await harness.start()
        let original = harness.session.composer.text
        let submission = Task { await harness.model.sendFromComposer(original) }
        try await eventually { harness.http.count("takeover") == 1 }
        submission.cancel(); gate.release()
        await submission.value
        #expect(harness.http.count("messages") == 0 && harness.session.composer.text == original)
        #expect(harness.model.error != nil)
    }

    @Test(arguments: ["text", "attachment", "voice", "ime"])
    func changedDraftDuringTakeoverIsPreservedWithoutSending(change: String) async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        let gate = TestGate(); harness.takeoverGate = gate
        try await harness.start()
        let original = harness.session.composer.text
        let submission = Task { await harness.model.sendFromComposer(original) }
        try await eventually { harness.http.count("takeover") == 1 }
        switch change {
        case "text": harness.session.composer.text = "用户后来修改的草稿"
        case "attachment": harness.session.composer.attachments = [.init(name: "new.txt", data: Data([1]), mediaType: "text/plain")]
        case "voice": harness.session.composer.isVoiceInputActive = true
        default: harness.session.composer.isComposing = true
        }
        let expectedText = harness.session.composer.text
        let expectedAttachments = harness.session.composer.attachments
        gate.release(); await submission.value
        #expect(harness.http.count("messages") == 0 && harness.model.error != nil)
        #expect(harness.session.composer.text == expectedText && harness.session.composer.attachments == expectedAttachments)
    }

    @Test func repeatedSendWhileTakeoverPendingProducesOneSubmission() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        let gate = TestGate(); harness.takeoverGate = gate
        try await harness.start()
        let text = harness.session.composer.text
        let first = Task { await harness.model.sendFromComposer(text) }
        try await eventually { harness.http.count("takeover") == 1 }
        await harness.model.sendFromComposer(text)
        #expect(harness.http.count("takeover") == 1 && harness.http.count("messages") == 0)
        gate.release(); await first.value
        #expect(harness.http.count("messages") == 1 && harness.session.pendingMessages.count == 1)
    }

    @Test func mismatchedInputNeverReplacesCurrentDraftOrTakesOver() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        try await harness.start()
        let original = harness.session.composer.text
        await harness.model.sendFromComposer("旧的输入框文字")
        #expect(harness.http.count("takeover") == 0 && harness.http.count("messages") == 0)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
    }

    @Test(arguments: ["voice", "ime", "invalid", "empty"])
    func unfinishedOrInvalidInputNeverTakesOverOrSends(state: String) async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        try await harness.start()
        switch state {
        case "voice": harness.session.composer.isVoiceInputActive = true
        case "ime": harness.session.composer.isComposing = true
        case "invalid": harness.session.composer.invalidate()
        default: harness.session.composer.text = "   "
        }
        let original = harness.session.composer.text
        await harness.model.sendFromComposer(original)
        #expect(harness.http.count("takeover") == 0 && harness.http.count("messages") == 0)
        #expect(harness.session.composer.text == original && harness.model.error != nil)
    }

    @Test func slashCommandIsResolvedAfterTakeoverInsteadOfSentAsMessage() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        try await harness.start()
        harness.session.composer.text = "/plan"
        await harness.model.sendFromComposer("/plan")
        #expect(harness.http.count("takeover") == 1 && harness.http.count("messages") == 0)
        #expect(harness.http.calls.filter { $0.path.hasSuffix("commands") && $0.method == .post }.count == 1)
        #expect(harness.model.commandSuccess != nil && harness.session.composer.text.isEmpty)
    }

    @Test(arguments: ["cancel", "edit"])
    func commandCatalogWaitCannotSendAnObsoleteSubmission(change: String) async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.takenOver = true
        let gate = TestGate(); harness.commandsGate = gate
        try await harness.start()
        harness.session.composer.text = "/plan"
        let submission = Task { await harness.model.sendFromComposer("/plan") }
        try await eventually { harness.http.calls.contains { $0.path.hasSuffix("commands") && $0.method == .get } }
        if change == "cancel" { submission.cancel() }
        else { harness.session.composer.text = "改为普通草稿" }
        let expected = harness.session.composer.text
        gate.release(); await submission.value
        #expect(harness.http.count("messages") == 0)
        #expect(harness.http.calls.filter { $0.path.hasSuffix("commands") && $0.method == .post }.isEmpty)
        #expect(harness.session.composer.text == expected && harness.model.error != nil)
    }

    @Test func uncertainTakeoverDuringCatalogReadCannotUseEarlierSendPermission() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.takenOver = true
        let gate = TestGate(); harness.commandsGate = gate
        try await harness.start()
        harness.session.composer.text = "/plan"
        let submission = Task { await harness.model.sendFromComposer("/plan") }
        try await eventually { harness.http.calls.contains { $0.path.hasSuffix("commands") && $0.method == .get } }
        harness.takeoverFailure = URLError(.timedOut)
        #expect(!(await harness.model.setTakeover(false)))
        #expect(harness.model.takeoverUncertain && harness.session.canSend)
        gate.release(); await submission.value
        #expect(harness.http.count("messages") == 0)
        #expect(harness.http.calls.filter { $0.path.hasSuffix("commands") && $0.method == .post }.isEmpty)
        #expect(harness.session.composer.text == "/plan" && harness.model.error != nil)
    }

    @Test func externallyPendingCommandCatalogCannotTurnASlashCommandIntoAMessage() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.takenOver = true
        let gate = TestGate(); harness.commandsGate = gate
        try await harness.start()
        let loading = Task { await harness.model.loadCommands() }
        try await eventually { harness.model.isLoadingCommands }
        harness.session.composer.text = "/plan"
        await harness.model.sendFromComposer("/plan")
        #expect(harness.http.count("messages") == 0)
        #expect(harness.http.calls.filter { $0.path.hasSuffix("commands") && $0.method == .post }.isEmpty)
        #expect(harness.session.composer.text == "/plan" && harness.model.error != nil)
        gate.release(); await loading.value
        #expect(harness.model.commands.count == 1 && !harness.model.isLoadingCommands)
        #expect(harness.http.count("messages") == 0)
    }

    @Test func failedCommandCatalogCannotTurnASlashCommandIntoAMessage() async throws {
        let harness = TakeoverSendHarness(); defer { harness.close() }
        harness.takenOver = true
        try await harness.start()
        harness.http.respond = { [weak harness] call in
            guard let harness else { throw CancellationError() }
            if call.path.hasSuffix("commands"), call.method == .get { throw URLError(.timedOut) }
            return try harness.http.defaultResponse(call)
        }
        harness.session.composer.text = "/plan"
        await harness.model.sendFromComposer("/plan")
        #expect(harness.model.commandsError != nil && harness.model.error != nil)
        #expect(harness.http.count("messages") == 0)
        #expect(harness.http.calls.filter { $0.path.hasSuffix("commands") && $0.method == .post }.isEmpty)
        #expect(harness.session.composer.text == "/plan")
    }
}

@MainActor private final class TakeoverSendHarness {
    let http = TestHTTPTransport()
    let realtime = TestRealtimeAPI()
    lazy var repo = repository(transport: http, realtime: realtime)
    lazy var session = repo.session(id: "session")
    lazy var model = SessionChatModel(session: session, repository: repo,
        attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
    var takenOver = false
    var supported = true
    var available = true
    var denialReason = "session_not_taken_over"
    var allowedAfterTakeover = true
    var blockingNotice = false
    var failFollowupRead = false
    var takeoverFailure: Error?
    var takeoverGate: TestGate?
    var commandsGate: TestGate?
    private var connection: Task<Void, Never>?

    init() {
        http.respond = { [weak self] call in
            guard let self else { throw CancellationError() }
            if call.path.hasSuffix("takeover") {
                await takeoverGate?.wait()
                if let takeoverFailure { throw takeoverFailure }
                takenOver = true
                return try fixtureData("takeover")
            }
            if call.path.hasSuffix("/state"), takenOver, failFollowupRead { throw URLError(.networkConnectionLost) }
            if call.path.hasSuffix("commands") {
                if call.method == .get { await commandsGate?.wait(); return try fixtureData("commands") }
                return try JSONSerialization.data(withJSONObject: ["ok": true,
                    "serverTime": "2026-10-30T00:00:00Z", "result": ["executionState": "completed"]])
            }
            if call.path.hasSuffix("snapshot") {
                var value = try fixtureObject("snapshot")
                var metadata = value["session"] as! [String: Any]
                metadata["takeover"] = takenOver; value["session"] = metadata
                value["effectiveCapabilities"] = try capabilitySet()
                value["notices"] = try notices()
                return try JSONSerialization.data(withJSONObject: value)
            }
            if call.path.hasSuffix("capabilities") {
                var value = try fixtureObject("capabilities"); value["capabilitySet"] = try capabilitySet()
                return try JSONSerialization.data(withJSONObject: value)
            }
            if call.path.hasSuffix("notices") {
                return try JSONSerialization.data(withJSONObject: ["notices": notices(), "serverTime": "2026-10-30T00:00:00Z"])
            }
            return try http.defaultResponse(call)
        }
    }

    func start() async throws {
        connection = Task { await session.connect() }
        try await eventually { self.session.connection == .connected && self.session.runtime.isFresh }
        session.composer.text = "最终转写：请检查登录页。"
    }

    func close() { connection?.cancel(); repo.reset() }

    private func capabilitySet() throws -> [String: Any] {
        let base = try fixtureObject("capabilities")["capabilitySet"] as! [String: Any]
        let source = (base["capabilities"] as! [[String: Any]])[0]
        let capabilities = ["session.send_message", "session.commands", "runtime.attachment"].map { id in
            var item = source
            item["capabilityId"] = id; item["scope"] = "session"; item["sessionId"] = "session"
            item["supported"] = supported; item["available"] = available
            item["allowed"] = takenOver && allowedAfterTakeover
            item["unavailableReason"] = takenOver ? (allowedAfterTakeover ? NSNull() : "permission_denied") : denialReason
            return item
        }
        return ["revision": 10, "capabilities": capabilities]
    }

    private func notices() throws -> [[String: Any]] {
        guard blockingNotice else { return [] }
        var notice = (try fixtureObject("notices")["notices"] as! [[String: Any]])[0]
        notice["blocking"] = ["scope": "session", "targetId": "session"]
        return [notice]
    }
}
