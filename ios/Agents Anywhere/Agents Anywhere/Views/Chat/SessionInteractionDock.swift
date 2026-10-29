import SwiftUI

/// All outstanding interactions share one horizontal card slot. Informational
/// notifications remain in the transcript instead of becoming response pages.
struct SessionInteractionDock: View {
    let chat: SessionChatModel
    let onShowAll: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // ScrollView may publish nil while a gesture is between pages. Preserve
    // that native transition instead of rejecting it through the session model.
    @State private var nativeScrollID: String?
    var metrics = SessionInteractionMetrics()

    private var items: [SessionNoticeModel] {
        SessionInteractionPager.items(chat.session.notices.notices, sessionID: chat.session.id,
            currentTurnItemIDs: chat.session.currentInteractionTurnItemIDs,
            isLatestWindow: !chat.session.hasNewerItems)
    }
    private var pager: SessionInteractionPager { chat.session.interactionPager }

    var body: some View {
        let pages = items
        Group {
            if !pages.isEmpty {
                pagesView(pages)
            }
        }
        .onChange(of: pages.map(\.id), initial: true) { _, next in
            pager.synchronize(next)
            if nativeScrollID != pager.selectedID { nativeScrollID = pager.selectedID }
        }
        .onChange(of: nativeScrollID) { _, next in
            if let next { pager.select(next) }
        }
        .onChange(of: pager.selectedID) { _, next in
            // Gesture-driven selection already matches the native position;
            // only buttons and queue changes need to move the scroll view.
            guard nativeScrollID != next else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { nativeScrollID = next }
        }
    }
    private func pagesView(_ pages: [SessionNoticeModel]) -> some View {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                        SessionInteractionCard(item: item, chat: chat,
                            page: pages.count > 1 ? "\(index + 1)/\(pages.count)" : nil,
                            height: metrics.compactHeight, onExpand: { onShowAll(item.id) },
                            onPrevious: pages.count > 1 ? { step(-1) } : nil,
                            onNext: pages.count > 1 ? { step(1) } : nil,
                            canGoPrevious: index > 0, canGoNext: index + 1 < pages.count)
                            .containerRelativeFrame(.horizontal)
                            .accessibilityHidden(pager.selectedID != nil && pager.selectedID != item.id)
                            .id(item.id)
                    }
                }.scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $nativeScrollID)
            .scrollIndicators(.hidden).scrollBounceBehavior(.basedOnSize)
            .frame(height: metrics.compactHeight).clipped()
            .accessibilityIdentifier("chat.interactions.pager")
            .padding(.horizontal, 24).padding(.vertical, 8)
    }
    private func step(_ delta: Int) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { pager.step(delta) }
    }
}
