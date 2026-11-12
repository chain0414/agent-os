import Foundation
import Observation
import Synchronization
import Testing
@testable import ClientCore

@Suite @MainActor struct SessionRepositoryTests {
    @Test(arguments: [
        HTTPError.server(statusCode: 409, message: "connector disconnected"),
        HTTPError.server(statusCode: 409, message: "Device is offline", detail: .object(["code": .string("connector_offline")]))
    ])
    func connectorDisconnectDuringLiveRefreshKeepsHistoryWithoutAnActionError(_ error: HTTPError) async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("/runtime/capabilities") { throw error }
            return try http.defaultResponse(call)
        }
        let model = repo.session(id: "session")
        let observation = Task { await model.connect() }
        defer { observation.cancel() }
        try await eventually { model.connection == .connected && http.count("/runtime/capabilities") > 0 }
        #expect(model.timeline.contains { $0.value.hasOpeningMessage })
        #expect(!model.runtime.isFresh)
        #expect(model.failure == nil)
    }

    @Test func openingPreviewIsReadableWhileHistoryIsPending() async throws {
        let http = TestHTTPTransport(), history = TestGate()
        let repo = repository(transport: http)
        defer { history.release(); repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("/opening-preview") {
                return Data(#"{"text":"Hello","truncated":true}"#.utf8)
            }
            if call.path.hasSuffix("/timeline") { await history.wait() }
            return try http.defaultResponse(call)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let chat = SessionChatModel(session: repo.session(id: summary.id), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        let opening = Task { await chat.prepareOpening(summary: summary, showPreview: true) }
        defer { opening.cancel() }
        try await eventually { chat.openingPreview?.text == "Hello" && http.count("/timeline") == 1 }
        #expect(repo.cached(sessionId: summary.id) == nil)
        #expect(!chat.isOpeningReady)
        history.release()
        await opening.value
        #expect(chat.isOpeningReady && chat.retainedOpeningPreview?.text == "Hello")
        let readable = try #require(chat.timeline.rows.last?.value)
        chat.finishPreviewHandoff(visible: readable)
        #expect(chat.openingPreview == nil)
        #expect(chat.timeline.rows.last?.id == "item")
        #expect(repo.cached(sessionId: summary.id)?.cursor == "seq:10")

        await chat.prepareOpening(summary: summary, showPreview: true)
        #expect(http.count("/opening-preview") == 1)
    }

    @Test func historyCanBecomeReadableWithoutWaitingForStalledPreview() async throws {
        let http = TestHTTPTransport(), preview = TestGate()
        let repo = repository(transport: http)
        defer { preview.release(); repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("/opening-preview") {
                await preview.wait()
                return Data(#"{"text":"Old preview","truncated":false}"#.utf8)
            }
            return try http.defaultResponse(call)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let chat = SessionChatModel(session: repo.session(id: summary.id), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        let opening = Task { await chat.prepareOpening(summary: summary, showPreview: true) }
        defer { opening.cancel() }
        try await eventually { chat.isOpeningReady && chat.timeline.rows.last?.id == "item" }
        #expect(!preview.released)
        preview.release()
        await opening.value
        #expect(chat.retainedOpeningPreview?.text == "Old preview")
    }

    @Test func differentHistoryDoesNotRemoveTheReadablePreview() async throws {
        let http = TestHTTPTransport(), history = TestGate()
        let repo = repository(transport: http)
        defer { history.release(); repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("/opening-preview") {
                return Data(#"{"text":"Newest message outside this page","truncated":false}"#.utf8)
            }
            if call.path.hasSuffix("/timeline") { await history.wait() }
            return try http.defaultResponse(call)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let chat = SessionChatModel(session: repo.session(id: summary.id), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        let opening = Task { await chat.prepareOpening(summary: summary, showPreview: true) }
        defer { opening.cancel() }
        try await eventually { chat.retainedOpeningPreview != nil }
        history.release()
        await opening.value
        #expect(chat.isOpeningReady)
        let older = try #require(chat.timeline.rows.last?.value)
        chat.finishPreviewHandoff(visible: older)
        #expect(chat.retainedOpeningPreview?.text == "Newest message outside this page")
        #expect(chat.timeline.rows.last?.id == "item")
    }

    @Test func coldDeadlineCancelsSlowHistoryAndRetryStartsAFreshRequest() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        http.respond = { _ in
            try await Task.sleep(for: .seconds(60))
            throw URLError(.cannotConnectToHost)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let chat = SessionChatModel(session: repo.session(id: summary.id), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        await chat.prepareOpening(summary: summary, showPreview: true, firstScreenTimeout: .seconds(2))
        #expect(chat.openingError != nil)
        #expect(http.count("/timeline") == 1)
        #expect(!chat.isOpeningReady)
        http.respond = { call in
            if call.path.hasSuffix("/opening-preview") {
                return Data(#"{"text":"Hello","truncated":false}"#.utf8)
            }
            return try http.defaultResponse(call)
        }
        await chat.prepareOpening(summary: summary, showPreview: true)
        #expect(http.count("/timeline") == 2)
        #expect(chat.isOpeningReady && chat.openingError == nil)
    }

    @Test func cancellingOpeningDiscardsALatePreview() async throws {
        let http = TestHTTPTransport(), preview = TestGate()
        let repo = repository(transport: http)
        defer { preview.release(); repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("/opening-preview") {
                await preview.wait()
                return Data(#"{"text":"A late preview","truncated":false}"#.utf8)
            }
            try await Task.sleep(for: .seconds(60))
            throw URLError(.cannotConnectToHost)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let chat = SessionChatModel(session: repo.session(id: summary.id), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        let opening = Task { await chat.prepareOpening(summary: summary, showPreview: true) }
        defer { opening.cancel() }
        try await eventually { http.count("/timeline") == 1 }
        opening.cancel()
        preview.release()
        await opening.value
        #expect(chat.retainedOpeningPreview == nil && chat.openingError == nil)
        #expect(repo.cached(sessionId: summary.id) == nil)
    }

    @Test func coldOpenRecoversAfterConnectivityReturns() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let chat = SessionChatModel(session: repo.session(id: summary.id), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        await chat.prepareOpening(summary: summary, showPreview: true)
        #expect(chat.openingError != nil && !chat.isOpeningReady)
        #expect(http.count("/timeline") == 0)

        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        await chat.prepareOpening(summary: summary, showPreview: true)
        #expect(chat.isOpeningReady && chat.openingError == nil)
        #expect(chat.timeline.rows.last?.id == "item")
    }

    @Test func toolOnlyWindowCannotSwallowOpeningRetry() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http)
        defer { repo.reset() }
        var previewAvailable = false
        http.respond = { call in
            if call.path.hasSuffix("/opening-preview") {
                return Data((previewAvailable
                    ? #"{"text":"Message before the tool tail","truncated":false}"#
                    : #"{"text":null,"truncated":false}"#).utf8)
            }
            if call.path.hasSuffix("/timeline") {
                var page = try fixtureObject("timeline")
                var tool = try itemObject()
                tool["type"] = "tool"
                tool["content"] = ["kind": "command", "command": "build"]
                page["items"] = [tool]
                page["hasMore"] = true
                return try JSONSerialization.data(withJSONObject: page)
            }
            return try http.defaultResponse(call)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let chat = SessionChatModel(session: repo.session(id: summary.id), repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        await chat.prepareOpening(summary: summary, showPreview: true)
        #expect(chat.needsReadableHistory && chat.openingError != nil)
        previewAvailable = true
        await chat.prepareOpening(summary: summary, showPreview: true)
        #expect(chat.retainedOpeningPreview?.text == "Message before the tool tail")
        #expect(chat.openingError == nil)
        #expect(http.count("/opening-preview") == 2)
        #expect(http.count("/timeline") == 2)
    }

    @Test func previousPageOwnerCannotCancelNewPageHistory() async throws {
        let http = TestHTTPTransport(), history = TestGate()
        let repo = repository(transport: http)
        defer { history.release(); repo.reset() }
        http.respond = { call in
            if call.path.hasSuffix("/timeline") { await history.wait() }
            try Task.checkCancellation()
            return try http.defaultResponse(call)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let previous = UUID(), current = UUID()
        repo.beginOpening(sessionId: summary.id, owner: previous)
        let first = Task { try await repo.open(sessionId: summary.id, summary: summary) }
        defer { first.cancel() }
        try await eventually { http.count("/timeline") == 1 }
        repo.beginOpening(sessionId: summary.id, owner: current)
        let second = Task { try await repo.open(sessionId: summary.id, summary: summary) }
        defer { second.cancel() }
        repo.cancelOpeningHistory(sessionId: summary.id, owner: previous)
        history.release()
        let opened = try await second.value
        #expect(opened.items.last?.id == "item")
        #expect(http.count("/timeline") == 1)
    }

    @Test func dashboardOpeningPublishesHistoryBeforeSlowMetadata() async throws {
        let http = TestHTTPTransport(), metadata = TestGate()
        let repo = repository(transport: http)
        defer { repo.reset(); metadata.release() }
        http.respond = { call in
            if call.path.hasSuffix("/meta") { await metadata.wait() }
            return try http.defaultResponse(call)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let session = repo.session(id: summary.id)
        let chat = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        let opening = Task { await chat.prepareOpening(summary: summary) }
        defer { opening.cancel() }
        try await eventually { chat.isOpeningReady }
        #expect(chat.timeline.rows.last?.id == "item")
        #expect(http.count("/meta") == 0)
        let observation = Task { await chat.timeline.run(sessionID: session.id, repository: repo) }
        defer { observation.cancel() }
        try await eventually { http.count("/meta") == 1 }
        try await eventually { session.runtime.isFresh }
        #expect(chat.timeline.rows.last?.id == "item")
    }

    @Test func prefetchReusesThePendingTimelineAndSkipsMeteredNetworks() async throws {
        let http = TestHTTPTransport(), timeline = TestGate(), realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset(); timeline.release() }
        let candidates = try ["session", "second", "third"].map { try snapshot(id: $0).session }
        repo.updateConnectivity(.init(availability: .online, isExpensive: true))
        await repo.prefetch(candidates)
        #expect(http.calls.isEmpty)

        http.respond = { call in
            if call.path == "/sessions/session/timeline" { await timeline.wait() }
            let id = String(call.path.split(separator: "/")[1])
            var page = try fixtureObject("timeline")
            page["sessionId"] = id
            page["items"] = try [itemObject(sessionID: id)]
            return try JSONSerialization.data(withJSONObject: page)
        }
        repo.updateConnectivity(.init(availability: .online))
        let prefetch = Task { await repo.prefetch(candidates) }
        defer { prefetch.cancel() }
        try await eventually { http.count("/timeline") == 1 }
        let summary = try #require(candidates.first)
        let opening = Task { try await repo.open(sessionId: summary.id, summary: summary) }
        defer { opening.cancel() }
        await Task.yield()
        timeline.release()
        let opened = try await opening.value
        await prefetch.value
        #expect(opened.items.last?.id == "item")
        #expect(http.calls.map(\.path) == ["/sessions/session/timeline", "/sessions/second/timeline"])
        #expect(realtime.tickets == 0)
    }

    @Test func slowColdHistoryShowsARetryAndCanOpenAfterwards() async throws {
        let http = TestHTTPTransport()
        let repo = repository(transport: http, openingTimeout: .milliseconds(100))
        defer { repo.reset() }
        http.respond = { _ in
            try await Task.sleep(for: .seconds(60))
            throw URLError(.cannotConnectToHost)
        }
        let summary = try fixture("session", as: V2SessionMetaResponse.self).session
        let session = repo.session(id: summary.id)
        let chat = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        await chat.prepareOpening(summary: summary)
        #expect(chat.openingError != nil)
        #expect(!chat.isOpeningReady)

        http.respond = nil
        await chat.prepareOpening(summary: summary)
        #expect(chat.openingError == nil)
        #expect(chat.isOpeningReady)
        #expect(chat.timeline.rows.last?.id == "item")
    }

    @Test func coldOpenShowsPersistedMessagesWhileConnectorIsOffline() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("/meta") {
                var meta = try fixtureObject("session")
                var session = try #require(meta["session"] as? [String: Any])
                session["connectorStatus"] = "offline"
                meta["session"] = session
                return try JSONSerialization.data(withJSONObject: meta)
            }
            guard call.path.hasSuffix("/timeline") else { throw URLError(.timedOut) }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }

        let opening = try await repo.open(sessionId: "session")

        #expect(opening.items.last?.id == "item")
        #expect(opening.session.connectorStatus == .offline)
        #expect(!repo.session(id: "session").canSend)
        #expect(http.calls.map(\.path) == ["/sessions/session/timeline", "/sessions/session/meta"])
    }

    @Test func openingAndCatchUpDoNotWaitForLiveNotices() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI(), noticesGate = TestGate()
        http.respond = { call in
            if call.path.hasSuffix("/notices") { await noticesGate.wait() }
            return try http.defaultResponse(call)
        }
        let arrival = try event("timeline.item_created", seq: 11,
            payload: ["item": itemObject(id: "arrived-during-open", order: 2, seq: 11)])
        realtime.onRecover = {
            V2EventRecoveryResponse(events: [arrival], nextCursor: "seq:11", snapshotRequired: false, serverTime: "")
        }
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset(); noticesGate.release() }
        let session = repo.session(id: "session")
        let chat = SessionChatModel(session: session, repository: repo,
            attachments: .init(attachmentAPI: V2AttachmentAPI(transport: http)))
        await chat.prepareOpening()
        #expect(chat.isOpeningReady)
        #expect(chat.timeline.rows.last?.id == "item")
        #expect(http.count("/notices") == 0)
        let observation = Task { await chat.timeline.run(sessionID: session.id, repository: repo) }
        defer { observation.cancel() }
        try await eventually { http.count("/notices") == 1 }
        try await eventually { chat.timeline.rows.last?.id == "arrived-during-open" }
        #expect(realtime.recoveries == ["seq:10"])
        #expect(!session.runtime.isFresh)
        #expect(!session.canSend)

        noticesGate.release()
        try await eventually { session.runtime.isFresh }
        #expect(session.notices.notices.map(\.id) == ["notice"])
    }

    @Test func openingStartsWithOnePageAndExplicitHistoryAccumulatesAgain() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("/timeline") {
                if call.query.contains(URLQueryItem(name: "mode", value: "latest")) {
                    #expect(call.query.contains(URLQueryItem(name: "limit", value: "24")))
                    var page = try fixtureObject("timeline")
                    page["items"] = try (277...300).map { try itemObject(id: "item-\($0)", order: $0) }
                    page["hasMore"] = true
                    return try JSONSerialization.data(withJSONObject: page)
                }
                #expect(call.query.contains(URLQueryItem(name: "limit", value: "100")))
                let before = try #require(call.query.first { $0.name == "beforeOrderSeq" }?.value.flatMap(Int.init))
                let start = max(1, before - 100)
                let items = try (start..<before).map { try itemObject(id: "item-\($0)", order: $0) }
                return try JSONSerialization.data(withJSONObject: ["sessionId": "session", "items": items,
                    "nextSeq": 1000, "hasMore": start > 1])
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let initial = try await repo.open(sessionId: "session")
        #expect(initial.items.count == 24 && initial.items.first?.orderSeq == 277)
        _ = try await repo.loadOlder(sessionId: "session")
        _ = try await repo.loadOlder(sessionId: "session")
        let all = try await repo.loadOlder(sessionId: "session")
        #expect(all.items.count == 300 && !all.hasOlderItems)
        let requests = http.calls.count
        let reopened = try await repo.open(sessionId: "session")
        #expect(reopened.items.map(\.orderSeq) == Array(201...300))
        #expect(reopened.hasOlderItems && !reopened.hasNewerItems && reopened.cursor == initial.cursor)
        #expect(http.calls.count == requests)
        let older = try await repo.loadOlder(sessionId: "session")
        #expect(older.items.map(\.orderSeq) == Array(101...300))
        #expect(http.calls.last?.query.contains { $0.name == "beforeOrderSeq" && $0.value == "201" } == true)
    }

    @Test func openingTurnFillsFourPagesAndKeepsTheCachedQueryWhenReopened() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            guard call.path.hasSuffix("/timeline") else { return try http.defaultResponse(call) }
            let before = call.query.first { $0.name == "beforeOrderSeq" }?.value.flatMap(Int.init)
            let start = before.map { max(1, $0 - 100) } ?? 378
            let orders = start..<(before ?? 402)
            let items = try orders.map { order in
                var row = try itemObject(id: "item-\(order)", order: order)
                if order == 101 {
                    row["role"] = "user"
                } else if order != 401 {
                    row["type"] = "tool"
                }
                row.removeValue(forKey: "turnId")
                return row
            }
            return try JSONSerialization.data(withJSONObject: ["sessionId": "session", "items": items,
                "nextSeq": 1000, "hasMore": start > 1])
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let first = try await repo.open(sessionId: "session")
        #expect(first.latestReply?.orderSeq == 401 && first.latestQueryIndex == nil)
        #expect(http.count("/timeline") == 1)
        let paired = try await repo.loadOlder(sessionId: "session", goal: .openingTurn)
        #expect(paired.latestQueryIndex.map { paired.items[$0].orderSeq } == 101)
        #expect(paired.items.first?.orderSeq == 101 && paired.hasOlderItems)
        #expect(http.count("/timeline") == 4)
        let reopened = try await repo.open(sessionId: "session")
        #expect(reopened.items.first?.orderSeq == 101 && reopened.latestReply?.orderSeq == 401)
        #expect(http.count("/timeline") == 4)
    }

    @Test func invalidHistoryPageLeavesTheCurrentReplyAndReportsFailureAtThePager() async throws {
        let http = TestHTTPTransport()
        http.respond = { call in
            guard call.path.hasSuffix("/timeline") else { return try http.defaultResponse(call) }
            var page = try fixtureObject("timeline")
            page["hasMore"] = true
            if call.query.contains(where: { $0.name == "beforeOrderSeq" }) { page["items"] = [] }
            return try JSONSerialization.data(withJSONObject: page)
        }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        _ = try await repo.open(sessionId: "session")
        await model.loadOlder()
        #expect(model.olderHistoryFeedback == .failed)
        #expect(model.failure == nil && model.hasOlderItems && !model.isLoadingHistory)
        #expect(model.timeline.contains { $0.value.hasOpeningMessage })
    }

    @Test func cachedModelLookupDoesNotSubscribeItsCallerToHistoricalRows() async throws {
        let http = TestHTTPTransport(), realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.connection == .connected }
        let row = try #require(model.timeline.first)
        let invalidated = Mutex(false)
        let same = withObservationTracking {
            repo.session(id: "session")
        } onChange: { invalidated.withLock { $0 = true } }
        #expect(same === model)
        realtime.yield(try event("timeline.item_updated", seq: 11,
            payload: ["item": itemObject(revision: 2, seq: 11, text: String(repeating: "Long reply. ", count: 2000))]))
        try await eventually { row.value.revision == 2 }
        #expect(!invalidated.withLock { $0 }, "Sidebar model lookup must not observe every message payload")
        #expect(model.timeline.first === row)
        #expect(repo.session(id: "session") === model)
    }

    @Test func concurrentLoadsShareRequestAndSessionIdentity() async throws {
        let http = TestHTTPTransport(); let gate = TestGate()
        http.respond = { call in await gate.wait(); return try http.defaultResponse(call) }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let first = Task { try await repo.load(sessionId: "session") }
        let second = Task { try await repo.load(sessionId: "session") }
        try await eventually { http.count("timeline") == 1 }
        gate.release()
        _ = try await first.value; _ = try await second.value
        #expect(http.count("timeline") == 1)
        #expect(repo.session(id: "session") === model)
        #expect(model.timeline.count == 1)
        #expect(!model.runtime.isFresh)
    }

    @Test func observersShareSocketRecoverAfterSubscribeAndKeepRowIdentity() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session")
        let one = Task { await model.connect() }; let two = Task { await model.connect() }
        defer { one.cancel(); two.cancel() }
        try await eventually { model.connection == .connected }
        #expect(realtime.tickets == 1)
        #expect(realtime.recoveries == ["seq:10"])
        #expect(model.canSend)
        let row = try #require(model.timeline.first)
        realtime.yield(try event("timeline.item_updated", seq: 11, payload: ["item": itemObject(revision: 2, seq: 11)]))
        try await eventually { row.value.revision == 2 }
        #expect(model.timeline.first === row)
        one.cancel(); _ = await one.result
        #expect(model.connection == .connected)
        two.cancel(); _ = await two.result
        try await eventually { model.connection == .inactive }
        #expect(!model.runtime.isFresh)
    }

    @Test func offlineRetainsDataAndDraftThenReconnectsWithFreshTicketAndCursor() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { model.connection == .connected }
        model.draft = "Unsent"
        realtime.yield(try event("timeline.item_created", seq: 11, payload: ["item": itemObject(id: "second", order: 2, seq: 11)]))
        try await eventually { model.timeline.count == 2 }
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        #expect(model.connection == .offline)
        #expect(model.timeline.count == 2)
        #expect(!model.canSend)
        #expect(model.draft == "Unsent")
        #expect(await model.sendDraft() == nil)
        _ = try await repo.load(sessionId: "session")
        #expect(http.count("timeline") == 1)
        repo.updateConnectivity(V2NetworkStatus(availability: .online, isExpensive: true, isConstrained: true))
        try await eventually { model.connection == .connected }
        #expect(realtime.tickets == 2)
        #expect(realtime.recoveries.last == "seq:11")
        #expect(model.canSend)
        #expect(model.network.isConstrained)
        #expect(http.count("messages") == 0)
    }

    @Test func suspendRetainsObserversAndResumesRecovery() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { model.connection == .connected }
        repo.suspend()
        #expect(model.connection == .inactive)
        #expect(model.timeline.count == 1)
        repo.resume()
        try await eventually { model.connection == .connected }
        #expect(realtime.tickets == 2)
    }

    @Test func resetRejectsLateResponsesAndClearsRetainedObjects() async throws {
        let http = TestHTTPTransport(); let gate = TestGate()
        http.respond = { call in await gate.wait(); return try http.defaultResponse(call) }
        let repo = repository(transport: http)
        let model = repo.session(id: "session"); model.draft = "Private draft"
        let load = Task { try await repo.load(sessionId: "session") }
        try await eventually { http.count("timeline") == 1 }
        repo.reset(); gate.release()
        if case .success = await load.result { Issue.record("Old account request populated a reset cache") }
        #expect(repo.cachedSessionIDs.isEmpty)
        #expect(!model.isValid)
        #expect(model.draft.isEmpty)
        #expect(model.metadata == nil)
    }

    @Test func lruEvictsInactiveSessionsButProtectsLocalWork() throws {
        let repo = repository(transport: TestHTTPTransport(), policy: V2SessionCachePolicy(maximumSessions: 2))
        defer { repo.reset() }
        let one = repo.session(id: "one"); one.draft = "Keep me"
        let two = repo.session(id: "two")
        _ = repo.session(id: "three")
        #expect(repo.cachedSessionIDs == ["one", "three"])
        #expect(one.isValid)
        #expect(!two.isValid)
    }

    @Test func catalogReadsCoalesceExpireAndInvalidateOnNetworkLoss() async throws {
        let http = TestHTTPTransport(); var date = Date()
        let repo = repository(transport: http, now: { date })
        defer { repo.reset() }
        async let one = repo.catalogs(sessionId: "session")
        async let two = repo.catalogs(sessionId: "session")
        _ = try await (one, two)
        #expect(http.count("catalogs/model") == 1)
        _ = try await repo.catalogs(sessionId: "session")
        #expect(http.count("catalogs/model") == 1)
        date += 31
        _ = try await repo.catalogs(sessionId: "session")
        #expect(http.count("catalogs/model") == 2)
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        do { _ = try await repo.catalogs(sessionId: "session"); Issue.record("Offline catalog was considered fresh") }
        catch { #expect((error as? V2ClientFailure)?.kind == .offline) }
        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        _ = try await repo.catalogs(sessionId: "session")
        #expect(http.count("catalogs/model") == 3)
    }

    @Test func snapshotRequiredMayRewindCursorAndThenRefreshLiveFacts() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { model.connection == .connected }
        realtime.yield(try event("vendor.updated", seq: 11))
        try await eventually { repo.cached(sessionId: "session")?.cursor == "seq:11" }
        realtime.onRecover = { V2EventRecoveryResponse(events: [], nextCursor: "seq:4", snapshotRequired: true, serverTime: "") }
        http.respond = { call in
            if call.path.hasSuffix("/timeline") {
                var page = try fixtureObject("timeline")
                page["nextSeq"] = 4
                return try JSONSerialization.data(withJSONObject: page)
            }
            return try http.defaultResponse(call)
        }
        realtime.yield(try event("session.refetch_required", seq: 12))
        try await eventually { repo.cached(sessionId: "session")?.cursor == "seq:4" }
        try await eventually { model.runtime.isFresh }
        #expect(http.count("timeline") == 2)
    }

    @Test func pendingSendTimeoutKeepsDraftAndDoesNotReplayThenEchoConfirms() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { model.canSend }
        http.respond = { call in
            if call.path.hasSuffix("messages") { throw URLError(.timedOut) }
            return try http.defaultResponse(call)
        }
        model.draft = "Hello again"
        let pending = try #require(await model.sendDraft())
        if case .uncertain = pending.delivery {} else { Issue.record("Timeout must leave delivery uncertain") }
        #expect(model.draft == "Hello again")
        #expect(await model.sendDraft() == nil)
        #expect(http.count("messages") == 1)
        realtime.yield(try event("timeline.item_created", seq: 11, payload: ["item": itemObject(id: "echo", order: 2, seq: 11, clientID: pending.id)]))
        try await eventually { pending.delivery == .confirmed }
        #expect(model.draft.isEmpty)
        #expect(model.pendingMessages.isEmpty)
        #expect(http.count("timeline") == 1)
    }

    @Test func echoBeforeHTTPFailureWinsAndConcurrentDraftEditsSurvive() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI(); let gate = TestGate()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let connection = Task { await model.connect() }
        defer { connection.cancel() }
        try await eventually { model.canSend }
        http.respond = { call in
            if call.path.hasSuffix("messages") { await gate.wait(); throw URLError(.networkConnectionLost) }
            return try http.defaultResponse(call)
        }
        model.draft = "First"
        let send = Task { await model.sendDraft() }
        try await eventually { http.count("messages") == 1 }
        let pending = try #require(model.pendingMessages.first)
        model.draft = "Next thought"
        realtime.yield(try event("timeline.item_created", seq: 11, payload: ["item": itemObject(id: "echo", order: 2, seq: 11, clientID: pending.id)]))
        try await eventually { pending.delivery == .confirmed }
        gate.release(); _ = await send.value
        #expect(pending.delivery == .confirmed)
        #expect(model.draft == "Next thought")
    }

    @Test func liveReadFailureNeverEnablesControlsAndAuthFailureStopsReconnect() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        http.respond = { call in
            if call.path.hasSuffix("/state") { throw HTTPError.server(statusCode: 401, message: "Expired") }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { model.failure?.kind == .authentication }
        #expect(!model.canSend)
        #expect(model.timeline.count == 1)
        #expect(realtime.tickets == 1)
        #expect(model.connection == .failed("Expired"))
    }

    @Test func catalogInvalidationRejectsLateInflightResponse() async throws {
        let http = TestHTTPTransport(); let gate = TestGate()
        http.respond = { call in await gate.wait(); return try http.defaultResponse(call) }
        let repo = repository(transport: http)
        defer { repo.reset() }
        let old = Task { try await repo.catalogs(sessionId: "session") }
        try await eventually { http.count("catalogs/model") == 1 }
        repo.updateConnectivity(V2NetworkStatus(availability: .offline))
        gate.release()
        if case .success = await old.result { Issue.record("An invalidated catalog read succeeded") }
        repo.updateConnectivity(V2NetworkStatus(availability: .online))
        _ = try await repo.catalogs(sessionId: "session")
        #expect(http.count("catalogs/model") == 2)
    }

    @Test func metadataBufferedBeforeLiveReadStillApplies() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI(); let gate = TestGate()
        realtime.onRecover = {
            await gate.wait()
            return V2EventRecoveryResponse(events: [], nextCursor: "seq:10", snapshotRequired: false, serverTime: "")
        }
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { realtime.recoveries.count == 1 }
        var meta = try fixtureObject("session")["session"] as! [String: Any]
        meta["title"] = "Renamed during recovery"
        realtime.yield(try event("session.meta.updated", payload: ["session": meta]))
        gate.release()
        try await eventually { model.metadata?.title == "Renamed during recovery" }
        #expect(model.canSend)
    }

    @Test func historyRequestCannotOverwriteANewerTimelineReset() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI(); let gate = TestGate()
        http.respond = { call in
            if call.path.hasSuffix("/timeline") {
                if call.query.contains(URLQueryItem(name: "mode", value: "history")) { await gate.wait() }
                var page = try fixtureObject("timeline")
                page["hasMore"] = true
                return try JSONSerialization.data(withJSONObject: page)
            }
            return try http.defaultResponse(call)
        }
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { model.canSend }
        let history = Task { try await repo.loadOlder(sessionId: "session") }
        try await eventually { http.count("timeline") == 2 }
        realtime.yield(try event("timeline.snapshot", seq: 11, payload: ["items": []]))
        try await eventually { model.timeline.isEmpty }
        gate.release()
        if case .success = await history.result { Issue.record("An older history page survived timeline reset") }
        #expect(model.timeline.isEmpty)
        #expect(repo.cached(sessionId: "session")?.cursor == "seq:11")
    }

    @Test func rejectedRuntimeActionDoesNotLookLikeSuccessfulSend() async throws {
        let http = TestHTTPTransport()
        http.respond = { _ in try fixtureData("rpcError") }
        let repo = repository(transport: http)
        defer { repo.reset() }
        do {
            _ = try await repo.send(sessionId: "session", content: "Hello", clientMessageID: "client")
            Issue.record("RPC ok:false was ignored")
        } catch { #expect((error as? V2RuntimeError)?.code == "notice_not_found") }
        #expect(http.count("messages") == 1)
        #expect(http.count("timeline") == 0)
    }

    @Test func confirmedTakeoverSurvivesAFailedFollowupReadWithoutReplaying() async throws {
        let http = TestHTTPTransport(); let realtime = TestRealtimeAPI()
        let repo = repository(transport: http, realtime: realtime)
        defer { repo.reset() }
        let model = repo.session(id: "session"); let task = Task { await model.connect() }
        defer { task.cancel() }
        try await eventually { model.canSend }
        http.respond = { call in
            if call.path.hasSuffix("/state") { throw URLError(.networkConnectionLost) }
            return try http.defaultResponse(call)
        }
        try await repo.setTakeover(sessionId: "session", enabled: true)
        #expect(model.metadata?.takeover == true)
        #expect(!model.runtime.isFresh && !model.canSend)
        #expect(model.failure != nil && http.count("takeover") == 1)
    }
}
