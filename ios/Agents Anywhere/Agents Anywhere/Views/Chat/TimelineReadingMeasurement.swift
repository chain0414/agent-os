import SwiftUI

extension EnvironmentValues {
    @Entry var timelineReadingWidth: CGFloat = 0
    @Entry var timelineReadingMeasurement: (String, CGRect, CGFloat, Bool) -> Void = { _, _, _, _ in }
}

/// Reports content coordinates, which do not change on each scroll offset.
struct TimelineReadingMeasurement: ViewModifier {
    let id: String
    var isParagraph = false
    @Environment(\.timelineReadingWidth) private var width
    @Environment(\.timelineReadingMeasurement) private var measured

    nonisolated private struct Sample: Equatable, Sendable {
        let frame: CGRect
        let width: CGFloat
    }

    func body(content: Content) -> some View {
        content.onGeometryChange(for: Sample.self) { geometry in
            Sample(frame: geometry.frame(in: .named("chat.timeline.content")), width: width)
        } action: { sample in
            measured(id, sample.frame, sample.width, isParagraph)
        }
    }
}
