import Foundation
import Observation

/// Selection belongs to the session; individual notices continue to own their
/// answers so switching pages never recreates or copies a response draft.
@MainActor @Observable final class SessionInteractionPager {
    private(set) var selectedID: String?
    private(set) var ids: [String] = []
    var selectedIndex: Int { ids.firstIndex(of: selectedID ?? "") ?? 0 }
    var pageNumber: Int { ids.isEmpty ? 0 : selectedIndex + 1 }

    static func items(_ notices: [SessionNoticeModel], sessionID: String) -> [SessionNoticeModel] {
        notices.filter { $0.notice.sessionId == sessionID && $0.notice.type == "interaction" && $0.isVisible }
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
