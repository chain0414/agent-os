import Foundation

/// Relative geometry for detecting layout changes and retaining history.
/// Tail visibility normally determines arrival at the latest message.
nonisolated struct TimelineViewport: Equatable {
    let contentHeight: CGFloat
    let visibleHeight: CGFloat
    let visibleBottom: CGFloat
    let offsetY: CGFloat
    let topInset: CGFloat
    let containerWidth: CGFloat

    init(contentHeight: CGFloat = 0, containerHeight: CGFloat = 0,
         topInset: CGFloat = 0, bottomInset: CGFloat = 0, offsetY: CGFloat = 0, containerWidth: CGFloat = 0) {
        self.contentHeight = max(0, contentHeight)
        visibleHeight = max(0, containerHeight - topInset - bottomInset)
        visibleBottom = offsetY + containerHeight - bottomInset
        self.offsetY = offsetY
        self.topInset = topInset
        self.containerWidth = containerWidth
    }
    var isMeasured: Bool { visibleHeight > 0 }

    var bottomOffset: CGFloat { max(-topInset, contentHeight - visibleHeight - topInset) }

    // Lazy rows can shrink after SwiftUI resolves an initial target. A visible
    // tail marker alone cannot distinguish the bottom from a nearly empty viewport.
    var isBeyondBottom: Bool {
        isMeasured && contentHeight > 0 && offsetY > bottomOffset + max(44, visibleHeight / 4)
    }
}
