import SwiftUI

/// Current input requests share one horizontal card slot. Informational
/// notifications remain in the transcript instead of becoming response pages.
struct SessionInteractionDock: View {
    let chat: SessionChatModel
    let onShowAll: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .onChange(of: pages.map(\.id), initial: true) { _, next in pager.synchronize(next) }
    }
    private func pagesView(_ pages: [SessionNoticeModel]) -> some View {
        TabView(selection: Binding<String>(get: {
            if let selectedID = pager.selectedID, pages.contains(where: { $0.id == selectedID }) { return selectedID }
            return pages[min(pager.selectedIndex, pages.count - 1)].id
        }, set: { pager.select($0) })) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                SessionInteractionCard(item: item, chat: chat,
                    page: pages.count > 1 ? "\(index + 1)/\(pages.count)" : nil,
                    height: metrics.compactHeight, onExpand: { onShowAll(item.id) },
                    onPrevious: pages.count > 1 ? { step(-1) } : nil,
                    onNext: pages.count > 1 ? { step(1) } : nil,
                    canGoPrevious: index > 0, canGoNext: index + 1 < pages.count)
                    .tag(item.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: metrics.compactHeight).clipped()
        .accessibilityIdentifier("chat.interactions.pager")
        .padding(.horizontal, 24).padding(.vertical, 8)
    }
    private func step(_ delta: Int) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { pager.step(delta) }
    }
}
