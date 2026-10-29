import SwiftUI

struct SessionNoticesSheet: View {
    let model: SessionChatModel
    var initialNoticeID: String? = nil
    @Environment(\.dismiss) private var dismiss
    private struct NoticeState: Equatable {
        let loadedIDs: [String]
        let visibleIDs: [String]
    }
    private var noticeState: NoticeState {
        let notices = model.session.notices.notices
        return NoticeState(loadedIDs: notices.map(\.id), visibleIDs: notices.filter(\.isVisible).map(\.id))
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(model.session.notices.notices.filter(\.isVisible)) { item in
                            SessionInteractionContent(item: item, chat: model).id(item.id)
                        }
                    }.padding(16)
                }
                .onAppear { if let initialNoticeID { proxy.scrollTo(initialNoticeID, anchor: .top) } }
            }
            .navigationTitle(String(localized: "交互与通知"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
        }
        .appSheetPresentation(.compact)
        .onChange(of: noticeState) { previous, next in
            if let initialNoticeID {
                // Waiting for initial data is different from an observed request
                // completing (or disappearing from an authoritative snapshot).
                let wasOrIsLoaded = previous.loadedIDs.contains(initialNoticeID) || next.loadedIDs.contains(initialNoticeID)
                if wasOrIsLoaded && !next.visibleIDs.contains(initialNoticeID) { dismiss() }
            } else if !previous.visibleIDs.isEmpty && next.visibleIDs.isEmpty {
                dismiss()
            }
        }
    }
}
