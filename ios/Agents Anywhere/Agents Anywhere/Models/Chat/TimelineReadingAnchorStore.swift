import Foundation

/// Session-owned reading intent survives compact/split view replacement. Frames
/// are deliberately not observable: scroll samples must not invalidate the list.
@MainActor final class TimelineReadingAnchorStore {
    struct Anchor: Equatable {
        let id: String
        let fraction: CGFloat
    }
    private struct Measurement {
        let y: CGFloat
        let height: CGFloat
        let width: CGFloat
        let isParagraph: Bool
    }
    private var measurements: [String: Measurement] = [:]
    private(set) var anchor: Anchor?
    private(set) var followsBottom = true

    func clear() {
        measurements.removeAll()
        anchor = nil
        followsBottom = true
    }

    func measure(id: String, y: CGFloat, height: CGFloat, width: CGFloat, isParagraph: Bool) {
        guard y.isFinite, height.isFinite, height > 0, width.isFinite, width > 0 else { return }
        measurements[id] = Measurement(y: y, height: height, width: width, isParagraph: isParagraph)
    }

    func capture(top: CGFloat, width: CGFloat, following: Bool) {
        followsBottom = following
        if following { anchor = nil; return }
        guard top.isFinite else { return }
        let candidates = measurements.filter { _, value in
            abs(value.width - width) < 1 && value.y <= top && value.y + value.height > top
        }
        // Prefer the paragraph containing the top edge to a whole long reply.
        if let match = candidates.min(by: { lhs, rhs in
            if lhs.value.isParagraph != rhs.value.isParagraph { return lhs.value.isParagraph }
            if lhs.value.height != rhs.value.height { return lhs.value.height < rhs.value.height }
            return lhs.key < rhs.key
        }) {
            anchor = Anchor(id: match.key, fraction: min(1, max(0, (top - match.value.y) / match.value.height)))
        }
    }

    func target(for anchor: Anchor, width: CGFloat) -> CGFloat? {
        guard let frame = measurements[anchor.id], abs(frame.width - width) < 1 else { return nil }
        return frame.y + frame.height * anchor.fraction
    }

    /// The first loaded row may be unmounted in a lazy list. Capture an actual
    /// currently-read group's frame while retaining the raw window boundary as
    /// a page revision marker (even when that first row is hidden automation).
    func historyLayout(firstRowID: String, groups: [ChatTimelineGroup], top: CGFloat,
                       width: CGFloat) -> TimelineHistoryLayout? {
        guard top.isFinite, width.isFinite, width > 0 else { return nil }
        let anchorRowID = anchor.map { String($0.id.components(separatedBy: ":block:")[0]) }
        let measured = groups.compactMap { group -> (ChatTimelineGroup, Measurement)? in
            guard let frame = measurements[group.id], abs(frame.width - width) < 1 else { return nil }
            return (group, frame)
        }
        let candidates = measured.filter { $0.1.y <= top && $0.1.y + $0.1.height > top }
        let candidate = candidates.first { group, _ in group.rows.contains { $0.id == anchorRowID } }
            ?? candidates.min { $0.1.height < $1.1.height }
            // A pull can place the viewport in the loading prompt or a gap.
            // Retain the nearest measured group instead of losing the anchor.
            ?? measured.min { lhs, rhs in
                func distance(_ frame: Measurement) -> CGFloat {
                    max(frame.y - top, top - frame.y - frame.height, 0)
                }
                return distance(lhs.1) < distance(rhs.1)
            }
        guard let (group, frame) = candidate else { return nil }
        let edge: TimelineHistoryLayout.Edge = group.rows.first?.structure.groupKind == .single ? .top : .bottom
        guard let row = edge == .top ? group.rows.first : group.rows.last else { return nil }
        return TimelineHistoryLayout(firstRowID: firstRowID, anchorRowID: row.id,
            edge: edge, y: edge == .top ? frame.y : frame.y + frame.height)
    }

    func retain(rowIDs: Set<String>) {
        measurements = measurements.filter { key, _ in
            rowIDs.contains(key) || rowIDs.contains(String(key.components(separatedBy: ":block:")[0]))
                || key.hasSuffix(":message-tail") && rowIDs.contains(String(key.dropLast(":message-tail".count)))
        }
        if let anchor, measurements[anchor.id] == nil { self.anchor = nil }
    }

    func historyLayout(firstRowID: String, entries: [TimelineRenderEntry], top: CGFloat,
                       width: CGFloat) -> TimelineHistoryLayout? {
        guard top.isFinite, width.isFinite, width > 0 else { return nil }
        let measured = entries.compactMap { entry -> (TimelineRenderEntry, Measurement)? in
            guard let frame = measurements[entry.id], abs(frame.width - width) < 1 else { return nil }
            return (entry, frame)
        }
        let containing = measured.filter { $0.1.y <= top && $0.1.y + $0.1.height > top }
        let candidate = containing.first { $0.0.id == anchor?.id }
            ?? containing.min { $0.1.height < $1.1.height }
            ?? measured.min { lhs, rhs in
                max(lhs.1.y - top, top - lhs.1.y - lhs.1.height, 0)
                    < max(rhs.1.y - top, top - rhs.1.y - rhs.1.height, 0)
            }
        guard let (entry, frame) = candidate else { return nil }
        let edge: TimelineHistoryLayout.Edge
        let target: String
        if case .group = entry.content, entry.group.rows.first?.structure.groupKind != .single {
            edge = .bottom; target = entry.group.rows.last?.id ?? entry.id
        } else { edge = .top; target = entry.id }
        return TimelineHistoryLayout(firstRowID: firstRowID, anchorRowID: target,
            edge: edge, y: edge == .top ? frame.y : frame.y + frame.height)
    }
}
