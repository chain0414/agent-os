import Foundation
import Observation

/// Parsed content belongs to the row, rather than a lazily mounted view. A
/// width change can therefore target an offscreen paragraph without reparsing.
@MainActor @Observable final class TimelineMarkdownPresentation {
    private(set) var blocks: [MarkdownBlockSnapshot] = []
    @ObservationIgnored private(set) var state = MarkdownParseState()
    @ObservationIgnored private(set) var deadlines: [Int: Date] = [:]
    @ObservationIgnored private(set) var parsedText: String?

    func publish(blocks: [MarkdownBlockSnapshot], state: MarkdownParseState, deadlines: [Int: Date], text: String? = nil) {
        self.state = state
        self.deadlines = deadlines
        parsedText = text
        if self.blocks != blocks { self.blocks = blocks }
    }

    func reset() {
        blocks = []
        state = MarkdownParseState()
        deadlines = [:]
        parsedText = nil
    }
}

/// Each entry is one direct child of the timeline's single lazy target layout.
/// A long message has several paragraph targets and exactly one tail, which
/// owns its attachments, notices, failure state and turn actions.
struct TimelineRenderEntry: Identifiable {
    enum Content { case group, markdown(MarkdownBlockSnapshot), messageTail }
    let id: String
    let group: ChatTimelineGroup
    let content: Content
    var isParagraph: Bool { if case .markdown = content { true } else { false } }

    static func build(groups: [ChatTimelineGroup]) -> [Self] {
        groups.flatMap { group -> [Self] in
            guard group.kind == .single, group.rows.count == 1,
                  let row = group.rows.first, row.usesBlockTimeline else {
                return [Self(id: group.id, group: group, content: .group)]
            }
            return row.markdown.blocks.map { block in
                Self(id: "\(row.id):block:\(block.id)", group: group, content: .markdown(block))
            } + [Self(id: "\(row.id):message-tail", group: group, content: .messageTail)]
        }
    }
}
