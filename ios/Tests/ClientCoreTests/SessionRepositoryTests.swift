import Foundation
import Observation
import Synchronization
import Testing
@testable import ClientCore

@Suite @MainActor struct SessionRepositoryTests {
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
