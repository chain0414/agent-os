import Foundation
import Observation

@MainActor @Observable
final class ChatTimelineRowModel: Identifiable {
    let id: V2TimelineItemID
    private(set) var value: V2TimelineItem
    private(set) var structure: TimelineRowStructure
    private(set) var text: String
    private(set) var isRevealing = false
    private(set) var layoutGeneration = 0
    private(set) var usesBlockTimeline = false
    let markdown = TimelineMarkdownPresentation()
    @ObservationIgnored private(set) var settlesAt: TimeInterval = 0
    @ObservationIgnored private var hasFlushed = false
    @ObservationIgnored private var entryCache: (cwd: String?, entry: TimelineEntryPresentation)?
    /// False while a streaming batch withholds the final glyph of the received text.
    @ObservationIgnored private var displaysFullText = false
    private var showsAutomationRecords = false
    @ObservationIgnored private(set) var automation: TimelineAutomationPresentation?
    var automationInstruction: TimelineAutomationInstruction? {
        guard !showsAutomationRecords, case let .instruction(_, text, timestamp) = automation else { return nil }
        return TimelineAutomationInstruction(text: text, timestamp: timestamp)
    }

    init(_ value: V2TimelineItem, animate: Bool = false) {
        id = value.id; self.value = value
        let automation = TimelineAutomationPresentation.classify(value)
        self.automation = automation
        structure = TimelineRowStructure(value)
        text = animate ? "" : automation?.bodyText ?? value.displayText
        usesBlockTimeline = Self.needsBlockTimeline(value, text: text)
    }

    /// Returns true when newly displayed text starts a reveal batch.
    @discardableResult
    func flush(_ next: V2TimelineItem, animate: Bool, now: TimeInterval) -> Bool {
        // Unchanged rows neither recompute their structure nor rescan their text.
        if hasFlushed && value == next && (animate || displaysFullText) { settle(now: now); return false }
        hasFlushed = true
        if value != next { automation = TimelineAutomationPresentation.classify(next) }
        let received = showsAutomationRecords ? next.displayText : automation?.bodyText ?? next.displayText
        let appending = received.hasPrefix(text)
        // Snapshots/corrections are authoritative replacements, not token deltas.
        if !appending { layoutGeneration += 1; markdown.reset() }
        let safeText = animate && appending && next.isStreamingText && !received.isEmpty
            ? String(received.dropLast()) : received
        let displayed = safeText.hasPrefix(text) || !appending ? safeText : received
        displaysFullText = displayed == received
        var started = false
        if displayed != text {
            isRevealing = animate && appending
            started = isRevealing
            if isRevealing { settlesAt = now + ReplyPresentation.revealSeconds + ReplyPresentation.drawSlack }
            text = displayed
        }
        let nextUsesBlockTimeline = Self.needsBlockTimeline(next, text: displayed)
        if usesBlockTimeline != nextUsesBlockTimeline { usesBlockTimeline = nextUsesBlockTimeline }
        if value != next { value = next; entryCache = nil }
        let nextStructure = TimelineRowStructure(next)
        if structure != nextStructure { structure = nextStructure }
        if !animate || now >= settlesAt { isRevealing = false }
        return started
    }

    private static func needsBlockTimeline(_ item: V2TimelineItem, text: String) -> Bool {
        item.type == .message && item.role == .assistant && text.utf8.count >= 16_000
    }

    func showAutomationRecords(_ show: Bool) {
        guard showsAutomationRecords != show else { return }
        showsAutomationRecords = show
        hasFlushed = false
        flush(value, animate: false, now: ProcessInfo.processInfo.systemUptime)
    }

    /// Tool/marker rows parse their payload once per item version instead of
    /// on every body evaluation of the row and its expanded details.
    func entry(cwd: String?) -> TimelineEntryPresentation {
        if let entryCache, entryCache.cwd == cwd { return entryCache.entry }
        let entry = TimelineEntryPresentation(item: value, cwd: cwd)
        entryCache = (cwd, entry)
        return entry
    }

    /// The drawing clock follows the last revealed batch, not the item's
    /// running status. A tool wait or thinking pause stops redrawing; the next
    /// appended text starts a new batch.
    func settle(now: TimeInterval) {
        if now >= settlesAt { isRevealing = false }
    }
}

/// Receives full repository projections without exposing each transport frame to
/// SwiftUI. Only flush() publishes rows. Received text waits in `pending` while
/// the previous batch reveals; the next batch goes on screen when it ends.
@MainActor @Observable
final class SessionTimelinePresentation {
    private(set) var rows: [ChatTimelineRowModel] = []
    private(set) var pendingMessages: [V2PendingMessage] = []
    private(set) var hasPresentedSnapshot = false
    var showsAutomationRecords = false {
        didSet {
            guard showsAutomationRecords != oldValue else { return }
            for row in rows { row.showAutomationRecords(showsAutomationRecords) }
        }
    }
    @ObservationIgnored private var rowsByID: [V2TimelineItemID: ChatTimelineRowModel] = [:]
    @ObservationIgnored private var pending: [V2TimelineItem]?
    @ObservationIgnored private var animatePending = false
    @ObservationIgnored private var initialized = false
    @ObservationIgnored private var lastConnection: V2SessionConnectionState = .inactive
    @ObservationIgnored private var wake: AsyncStream<Void>.Continuation?
    @ObservationIgnored private var observationGeneration = 0
    /// When the newest reveal batch ends and the buffer may publish again.
    @ObservationIgnored private(set) var nextBatchAt: TimeInterval = 0

    func presentOpening(_ items: [V2TimelineItem], pendingMessages: [V2PendingMessage]) {
        stage(items, animate: false)
        flush()
        synchronizePending(pendingMessages)
    }

    func receive(_ observation: V2SessionObservation) {
        defer { lastConnection = observation.connection }
        guard let data = observation.data else { return }
        stage(data.items, animate: initialized && lastConnection == .connected && observation.connection == .connected)
        initialized = true
    }

    func stage(_ items: [V2TimelineItem], animate: Bool) {
        pending = items.filter(\.isVisibleInChat)
        // Once a recovery snapshot is staged, preserve its snap semantics until
        // that tick even if a live event arrives immediately afterwards.
        animatePending = pendingWasStaged ? animatePending && animate : animate
        pendingWasStaged = true
        wake?.yield(())
    }
    @ObservationIgnored private var pendingWasStaged = false

    func flush(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let pending {
            let previousTail = rows.last?.value.orderSeq ?? Int.min
            var started = false
            var updated: [ChatTimelineRowModel] = []
            updated.reserveCapacity(pending.count)
            var orderChanged = pending.count != rows.count
            for (index, value) in pending.enumerated() {
                let existing = rowsByID[value.id]
                let animate = animatePending && (existing != nil || value.orderSeq > previousTail)
                let row: ChatTimelineRowModel
                if let existing { row = existing } else {
                    row = ChatTimelineRowModel(value, animate: animate && value.isAssistantText)
                    row.showAutomationRecords(showsAutomationRecords)
                    rowsByID[value.id] = row
                }
                if row.flush(value, animate: animate, now: now) { started = true }
                if !orderChanged, rows[index] !== row { orderChanged = true }
                updated.append(row)
            }
            // Complete automation envelopes carry their own visible body. Keep
            // every message in the transcript, even if pagination omitted the
            // matching instruction or the backend supplied no turn IDs.
            if started { nextBatchAt = now + ReplyPresentation.batchInterval }
            if orderChanged {
                rows = updated
                rowsByID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
            }
            if !hasPresentedSnapshot { hasPresentedSnapshot = true }
            self.pending = nil; pendingWasStaged = false
        }
        for row in rows where row.isRevealing { row.settle(now: now) }
    }

    func run(sessionID: V2SessionID, repository: V2SessionRepository) async {
        observationGeneration += 1
        let generation = observationGeneration
        let session = repository.session(id: sessionID)
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = signal.continuation
        defer {
            signal.continuation.finish()
            if observationGeneration == generation { wake = nil }
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                defer { signal.continuation.finish() }
                for await value in repository.observe(sessionId: sessionID) {
                    guard !Task.isCancelled, let self else { return }
                    self.receive(value)
                }
            }
            group.addTask { @MainActor [weak self] in
                for await _ in signal.stream {
                    guard !Task.isCancelled, let self else { return }
                    repeat {
                        // Text received during a reveal waits for it to end, then
                        // goes on screen as one batch. Text after a pause shows at
                        // once. Without new text, poll briefly to notice arrivals
                        // and settle rows whose reveal has ended.
                        let now = ProcessInfo.processInfo.systemUptime
                        // Without new text, sleep until the earliest reveal ends
                        // instead of waking at a fixed cadence.
                        let wait = self.pending != nil ? self.nextBatchAt - now
                            : max(Self.minimumIdleWait, (self.rows.filter(\.isRevealing).map(\.settlesAt).min() ?? now) - now)
                        if wait > 0 {
                            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                        }
                        let current = ProcessInfo.processInfo.systemUptime
                        guard self.pending == nil || current >= self.nextBatchAt else { continue }
                        self.flush(now: current)
                        self.synchronizePending(session.pendingMessages)
                    } while !Task.isCancelled && (self.pending != nil || self.rows.contains { $0.isRevealing })
                }
            }
            await group.waitForAll()
        }
    }

    private static let minimumIdleWait: TimeInterval = 1.0 / 60

    func synchronizePending(_ messages: [V2PendingMessage]) {
        // Change optimistic membership in the same tick that publishes echoes,
        // avoiding a blank first user row between HTTP/realtime and UI clocks.
        let visible = messages.filter { message in
            !rows.contains { $0.value.role == .user && $0.value.source["clientMessageId"]?.stringValue == message.id }
        }
        if pendingMessages.map(\.id) != visible.map(\.id) { pendingMessages = visible }
    }

    func disclosureTarget(for key: String) -> String? {
        if let row = rows.first(where: {
            UserMessageExpansionStore.key(itemID: $0.id,
                clientMessageID: $0.value.source["clientMessageId"]?.stringValue) == key
        }) { return row.id }
        return pendingMessages.first { "client:\($0.id)" == key }?.id
    }
}

extension V2TimelineItem {
    var isAssistantText: Bool {
        isReasoning || type == .message && role == .assistant
    }
    var isStreamingText: Bool {
        (status == .pending || status == .running)
            && isAssistantText
    }
}
