import Foundation
import Testing
@testable import ClientCore

@Suite struct ChatTitleVisibilityTests {
    @Test func initialTitleDisappearsAfterOneAndHalfSeconds() {
        var state = ChatTitleVisibilityState()
        state.begin(now: 0)
        state.expire(now: 1.49); #expect(state.isVisible)
        state.expire(now: 1.5); #expect(!state.isVisible)
    }
    @Test func userDragAndMomentumKeepTitleUntilSettled() {
        var state = ChatTitleVisibilityState()
        state.begin(now: 0); state.expire(now: 2)
        state.scrollChanged(.interacting, now: 3); #expect(state.isVisible)
        state.expire(now: 20); #expect(state.isVisible)
        state.scrollChanged(.decelerating, now: 21)
        state.expire(now: 30); #expect(state.isVisible)
        state.scrollChanged(.idle, now: 31)
        state.expire(now: 32.49); #expect(state.isVisible)
        state.expire(now: 32.5); #expect(!state.isVisible)
    }
    @Test func automaticFollowingDoesNotRevealOrPostponeTitle() {
        var state = ChatTitleVisibilityState()
        state.begin(now: 0)
        state.scrollChanged(.animating, now: 1)
        state.scrollChanged(.idle, now: 1.2)
        state.expire(now: 1.5); #expect(!state.isVisible)
        state.scrollChanged(.animating, now: 2)
        state.scrollChanged(.idle, now: 3); #expect(!state.isVisible)
    }
    @Test func interruptedHideCannotHideANewDrag() {
        var state = ChatTitleVisibilityState()
        state.begin(now: 0)
        state.scrollChanged(.interacting, now: 1)
        state.scrollChanged(.idle, now: 2)
        state.scrollChanged(.interacting, now: 3)
        state.expire(now: 4); #expect(state.isVisible)
        #expect(state.hideAt == nil)
    }
    @Test func trackingAloneDoesNotRevealHiddenTitle() {
        var state = ChatTitleVisibilityState()
        state.begin(now: 0); state.expire(now: 2)
        state.scrollChanged(.tracking, now: 3); #expect(!state.isVisible)
    }
    @Test func voiceOverCanKeepContextVisible() {
        var state = ChatTitleVisibilityState()
        state.begin(now: 0); state.scrollChanged(.interacting, now: 0.5); state.pin(true, now: 1)
        state.expire(now: 100); #expect(state.isVisible)
        state.pin(false, now: 101)
        state.expire(now: 102.5); #expect(!state.isVisible)
    }
}
