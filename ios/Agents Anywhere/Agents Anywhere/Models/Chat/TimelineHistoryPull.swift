import Foundation

/// One fresh pull beyond a visible history edge loads one page on release.
/// Inertia, automatic scrolling and resizing cannot arm either edge.
nonisolated struct TimelineHistoryPull: Equatable {
    enum Edge: Equatable { case older, latest }
    var edge = Edge.latest

    // `private var origin` makes the synthesized memberwise initializer private,
    // while the all-defaulted `init()` stays internal. Callers that pass an edge
    // need an accessible initializer.
    init(edge: Edge = .latest) { self.edge = edge }
    private var origin: TimelineViewport?
    private(set) var isReady = false

    mutating func begin(at viewport: TimelineViewport, promptVisible: Bool, canLoad: Bool) {
        origin = promptVisible && canLoad ? viewport : nil
        isReady = false
    }

    mutating func update(_ viewport: TimelineViewport) {
        guard let origin else { return }
        // Live rows can grow below the older edge without moving that edge.
        guard abs(viewport.visibleHeight - origin.visibleHeight) <= 2,
              abs(viewport.containerWidth - origin.containerWidth) <= 2,
              abs(viewport.topInset - origin.topInset) <= 2,
              edge == .older || abs(viewport.contentHeight - origin.contentHeight) <= 2 else {
            cancel()
            return
        }
        let movement = edge == .older
            ? origin.offsetY - viewport.offsetY
            : viewport.visibleBottom - origin.visibleBottom
        isReady = movement >= 24
    }

    mutating func end() -> Bool {
        let shouldLoad = isReady
        cancel()
        return shouldLoad
    }

    mutating func cancel() { origin = nil; isReady = false }
}
