import Foundation
import Observation

struct ChatTimelineGroup: Identifiable, Equatable {
    enum Kind: Equatable { case single, tools, completedTurn, reconnect, agents(String) }
    let kind: Kind
    let rows: [ChatTimelineRowModel]
    var startsTurn = false
    var endsAtHiddenTurnBoundary = false
    var executionDuration: TimeInterval?
    var executionStatus: V2TimelineItemStatus?
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind && lhs.startsTurn == rhs.startsTurn
            && lhs.executionDuration == rhs.executionDuration && lhs.executionStatus == rhs.executionStatus
            && lhs.endsAtHiddenTurnBoundary == rhs.endsAtHiddenTurnBoundary
            && lhs.rows.elementsEqual(rhs.rows, by: ===)
    }
    // The first row owns the group, even as the second tool arrives. A group
    // growing during a stream does not replace the scroll target or its state.
    var id: String { rows[0].id }
    var status: V2TimelineItemStatus {
        if let executionStatus { return executionStatus }
        if let active = rows.first(where: { $0.structure.status.isActive }) { return active.structure.status }
        if let failure = rows.first(where: { $0.structure.status.isFailure }) { return failure.structure.status }
        return rows.contains(where: { $0.structure.status == .unknown }) ? .unknown : .done
    }
    var title: String {
        switch kind {
        case .single: return ""
        case .agents: return executionTitle
        case .reconnect:
            let attempts = rows.compactMap { $0.structure.reconnectAttempt }
            // The full retry messages remain available in the expanded rows.
            return String(localized: "连接重试 · \(rows.count) 次") + (attempts.last.map { "（\($0)）" } ?? "")
        case .tools: return executionTitle
        case .completedTurn:
            guard let executionDuration else { return status.label }
            return String(localized: "用时 \(TimelineExecutionTiming.formatted(executionDuration))")
        }
    }
    private var executionTitle: String {
        guard !status.isActive, status != .unknown, let executionDuration else { return status.label }
        let elapsed = TimelineExecutionTiming.formatted(executionDuration)
        return String(localized: "\(status.label)，用时 \(elapsed)")
    }

}

enum TimelineGrouping {
    static func groups(_ rows: [ChatTimelineRowModel], interactionTargets: Set<String>,
                       latestTurnIsComplete: Bool? = nil) -> [ChatTimelineGroup] {
        var groups: [ChatTimelineGroup] = []
        var pending: [ChatTimelineRowModel] = []
        var pendingKind = ChatTimelineGroup.Kind.single
        var pendingStartsTurn = false
        var nextStartsTurn = false
        var previousTurnID: String?
        func foldsTool(_ row: ChatTimelineRowModel) -> Bool {
            row.structure.type == .tool || row.structure.isFileChange
        }
        func flush() {
            guard !pending.isEmpty else { return }
            groups.append(ChatTimelineGroup(kind: pending.count > 1 || foldsTool(pending[0]) ? pendingKind : .single, rows: pending,
                startsTurn: pendingStartsTurn))
            pending = []
            pendingStartsTurn = false
        }
        for row in rows {
            let protected = interactionTargets.contains(row.id)
            if row.structure.startsTurn {
                flush()
                nextStartsTurn = true
                if row.structure.isAutomationHidden, !protected, !groups.isEmpty {
                    groups[groups.count - 1].endsAtHiddenTurnBoundary = true
                }
            }
            if row.structure.isAutomationHidden, !protected { continue }
            if let turnID = row.structure.turnID {
                if let previousTurnID, previousTurnID != turnID {
                    flush()
                    nextStartsTurn = true
                }
                previousTurnID = turnID
            }
            let kind = row.structure.groupKind
            if kind == .single || protected {
                flush()
                groups.append(ChatTimelineGroup(kind: foldsTool(row) ? kind : .single, rows: [row], startsTurn: nextStartsTurn))
                nextStartsTurn = false
                continue
            }
            if pendingKind != kind { flush() }
            if pending.isEmpty { pendingStartsTurn = nextStartsTurn; nextStartsTurn = false }
            pendingKind = kind; pending.append(row)
        }
        flush()
        // A native duration describes the whole turn, including parallel tools.
        // Only its last process section shows it; never sum per-item copies.
        var previousExecutionIndex: Int?
        for index in groups.indices {
            if groups[index].startsTurn { previousExecutionIndex = nil }
            switch groups[index].kind {
            case .tools, .agents:
                let timing = groups[index].rows.compactMap { $0.structure.executionTiming }.last
                groups[index].executionStatus = timing?.status
                groups[index].executionDuration = timing?.duration
                if let previousExecutionIndex { groups[previousExecutionIndex].executionDuration = nil }
                previousExecutionIndex = index
            default: break
            }
        }
        guard let latestTurnIsComplete else { return groups }
        var folded: [ChatTimelineGroup] = []
        var start = 0
        for index in groups.indices {
            guard index > start,
                  groups[index].startsTurn || groups[index - 1].endsAtHiddenTurnBoundary else { continue }
            folded += foldCompletedTurn(groups[start..<index], interactionTargets: interactionTargets)
            start = index
        }
        let tail = groups[start...]
        folded += latestTurnIsComplete || tail.last?.endsAtHiddenTurnBoundary == true
            ? foldCompletedTurn(tail, interactionTargets: interactionTargets) : Array(tail)
        return folded
    }

    private static func foldCompletedTurn(_ groups: ArraySlice<ChatTimelineGroup>,
                                          interactionTargets: Set<String>) -> [ChatTimelineGroup] {
        let rows = groups.flatMap(\.rows)
        let timings = rows.compactMap { $0.structure.executionTiming }
        guard let reply = rows.last(where: { $0.structure.isAssistantMessage }),
              reply.structure.status == .done, !reply.structure.isCommentary,
              !rows.contains(where: { $0.structure.status.isActive }),
              timings.last(where: { $0.status != nil })?.status.map({ $0 == .done }) ?? true else {
            return Array(groups)
        }
        func isProcess(_ group: ChatTimelineGroup) -> Bool {
            group.rows.allSatisfy { row in
                guard row !== reply, !interactionTargets.contains(row.id) else { return false }
                switch row.structure.groupKind {
                case .tools, .agents: return true
                case .single: return row.structure.isAssistantMessage && row.automation == nil
                default: return false
                }
            }
        }
        let process = groups.filter(isProcess)
        guard let last = process.last,
              let replyIndex = groups.firstIndex(where: { $0.id == reply.id }),
              let lastProcessIndex = groups.firstIndex(where: { $0.id == last.id }),
              lastProcessIndex < replyIndex else {
            return Array(groups)
        }
        let processIDs = Set(process.map(\.id))
        let duration = timings.compactMap(\.duration).last
        var result: [ChatTimelineGroup] = []
        var run: [ChatTimelineGroup] = []
        func appendRun() {
            guard let first = run.first else { return }
            result.append(ChatTimelineGroup(kind: .completedTurn, rows: run.flatMap(\.rows),
                startsTurn: first.startsTurn,
                executionDuration: run.last?.id == last.id ? duration : nil, executionStatus: .done))
            run.removeAll(keepingCapacity: true)
        }
        for group in groups {
            if processIDs.contains(group.id) { run.append(group) }
            else { appendRun(); result.append(group) }
        }
        appendRun()
        return result
    }

    static func reconnectMessage(_ item: V2TimelineItem) -> String? {
        guard item.type == .system, item.status == .failed else { return nil }
        let raw = item.raw["content"]
        let message = TimelineText.first(raw?["details"]?["error"]?["message"], raw?["details"]?["message"], raw?["message"], raw?["text"])
        return message?.hasPrefix("Reconnecting...") == true ? message : nil
    }
}

@MainActor @Observable final class TimelineDisclosureState {
    @Observable fileprivate final class Entry { var expanded = false }
    @ObservationIgnored private var entries: [String: Entry] = [:]
    private func entry(_ id: String) -> Entry {
        if let existing = entries[id] { return existing }
        let value = Entry(); entries[id] = value; return value
    }
    // Each fold observes its own bit. Toggling one tool must not reconstruct
    // every other expanded tool's diff and output subtree.
    func isExpanded(_ id: String) -> Bool { entry(id).expanded }
    func toggle(_ id: String) { entry(id).expanded.toggle() }
}

/// Only native execution metadata is eligible. Server persistence timestamps
/// describe synchronization, including historical imports, rather than work.
struct TimelineExecutionTiming: Equatable {
    let duration: TimeInterval?
    let status: V2TimelineItemStatus?
    init?(_ item: V2TimelineItem) {
        guard case let .object(value) = item.raw["content"]?["turnTiming"] else { return nil }
        func number(_ key: String) -> Double? {
            guard case let .number(value) = value[key], value.isFinite else { return nil }
            return value
        }
        let milliseconds = number("durationMs")
            ?? number("startedAt").flatMap { start in
                guard start >= 0, let end = number("completedAt"), end >= start else { return nil }
                return end - start
            }
        if let milliseconds, milliseconds >= 0, milliseconds < Double(Int.max) {
            duration = milliseconds / 1000
        } else { duration = nil }
        switch value["status"]?.stringValue {
        case "completed", "done": status = .done
        case "inProgress", "running": status = .running
        case "pending": status = .pending
        case "waiting_approval": status = .waitingApproval
        case "failed": status = .failed
        case "interrupted": status = .interrupted
        case "cancelled": status = .cancelled
        case nil: status = nil
        default: status = .unknown
        }
    }
    static func formatted(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(localized: "不足 1 秒") }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = total / 60 % 60, remainder = total % 60
        if hours > 0 { return String(localized: "\(hours) 小时 \(minutes) 分钟") }
        if minutes > 0 { return String(localized: "\(minutes) 分 \(remainder) 秒") }
        return String(localized: "\(remainder) 秒")
    }
}
