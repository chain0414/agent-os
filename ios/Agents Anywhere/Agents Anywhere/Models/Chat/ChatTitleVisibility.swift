import Foundation
import Observation

/// Deadlines use a monotonic clock. Programmatic following cannot reveal the
/// title or extend an existing deadline; only an actual user drag can do that.
struct ChatTitleVisibilityState {
    private(set) var isVisible = true
    private(set) var hideAt: TimeInterval?
    private var userIsScrolling = false
    private var pinned = false
    mutating func begin(now: TimeInterval) {
        isVisible = true; userIsScrolling = false
        hideAt = pinned ? nil : now + 1.5
    }
    mutating func scrollChanged(_ phase: TimelineScrollState.Phase, now: TimeInterval) {
        guard !pinned else { return }
        switch phase {
        case .interacting, .decelerating:
            isVisible = true; userIsScrolling = true; hideAt = nil
        case .tracking:
            if isVisible { hideAt = nil }
        case .idle:
            userIsScrolling = false
            if isVisible && hideAt == nil { hideAt = now + 1.5 }
        case .animating: break
        }
    }
    mutating func expire(now: TimeInterval) {
        guard !pinned, !userIsScrolling, let hideAt, now >= hideAt else { return }
        isVisible = false; self.hideAt = nil
    }
    mutating func pin(_ enabled: Bool, now: TimeInterval) {
        guard pinned != enabled else { return }
        pinned = enabled
        if enabled { isVisible = true; userIsScrolling = false; hideAt = nil }
        else if !userIsScrolling { hideAt = now + 1.5 }
    }
}

@MainActor @Observable final class ChatTitleVisibility {
    private(set) var isVisible = true
    @ObservationIgnored private var state = ChatTitleVisibilityState()
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var scheduledDeadline: TimeInterval?

    func begin() { state.begin(now: now); synchronize() }
    func end() { timer?.cancel(); timer = nil; scheduledDeadline = nil }
    func scrollChanged(_ phase: TimelineScrollState.Phase) {
        state.scrollChanged(phase, now: now); synchronize()
    }
    func setAlwaysVisible(_ enabled: Bool) { state.pin(enabled, now: now); synchronize() }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private func synchronize() {
        if isVisible != state.isVisible { isVisible = state.isVisible }
        guard scheduledDeadline != state.hideAt else { return }
        timer?.cancel(); timer = nil
        scheduledDeadline = state.hideAt
        guard let deadline = scheduledDeadline else { return }
        let delay = max(0, deadline - now)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, !Task.isCancelled, self.scheduledDeadline == deadline else { return }
            self.scheduledDeadline = nil; self.timer = nil
            self.state.expire(now: self.now)
            self.synchronize()
        }
    }
}
