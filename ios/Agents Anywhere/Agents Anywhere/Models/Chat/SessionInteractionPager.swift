import Foundation
import Observation

/// Selection belongs to the session; individual notices continue to own their
/// answers so switching pages never recreates or copies a response draft.
@MainActor @Observable final class SessionInteractionPager {
    private(set) var selectedID: String?
    private(set) var ids: [String] = []
    var selectedIndex: Int { ids.firstIndex(of: selectedID ?? "") ?? 0 }
    var pageNumber: Int { ids.isEmpty ? 0 : selectedIndex + 1 }

    static func items(_ notices: [SessionNoticeModel], sessionID: String,
                      currentTurnItemIDs: Set<String> = [], isLatestWindow: Bool = true) -> [SessionNoticeModel] {
        notices.filter { item in
            guard item.notice.sessionId == sessionID, item.notice.type == "interaction", item.isVisible else { return false }
            // A runtime blocker remains actionable regardless of its scope or
            // whether its target has scrolled out of the loaded history window.
            if item.notice.blocking != nil { return true }
            guard isLatestWindow else { return false }
            // Historical nonblocking questions remain available in details but
            // must not masquerade as the current turn's input request.
            guard let target = item.timelineTargetID else { return true }
            return currentTurnItemIDs.contains(target)
        }
    }
    static func latestTurnItemIDs(in timeline: [V2TimelineItem]) -> Set<String> {
        let start = timeline.lastIndex { $0.type == .message && $0.role == .user } ?? timeline.startIndex
        return Set(timeline[start...].map(\.id))
    }
    func synchronize(_ next: [String]) {
        guard next != ids else { return }
        let previousIndex = selectedIndex
        ids = next
        if let selectedID, next.contains(selectedID) { return }
        selectedID = next.isEmpty ? nil : next[min(previousIndex, next.count - 1)]
    }
    func select(_ id: String?) {
        guard let id, ids.contains(id) else { return }
        selectedID = id
    }
    func step(_ delta: Int) {
        let next = selectedIndex + delta
        guard ids.indices.contains(next) else { return }
        selectedID = ids[next]
    }
}
