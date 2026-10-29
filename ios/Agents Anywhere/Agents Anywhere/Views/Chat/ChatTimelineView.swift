import SwiftUI
#if DEBUG
import OSLog
#endif

struct ChatTimelineView: View {
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void
    @State private var historyLayout: TimelineHistoryLayout?
    @State private var historyPosition: TimelineHistoryPosition?
    @State private var hasRequestedOlder = false
    @State private var position = ScrollPosition()
    @State private var scrolling = TimelineScrollState()
    @State private var viewportSample = ChatViewportSample()
    @State private var viewportUpdates = ChatLayoutUpdate<TimelineViewport>()
    @State private var historyUpdates = ChatLayoutUpdate<TimelineHistoryLayout>()
    @State private var latestPull = TimelineHistoryPull()
    @State private var olderPull = TimelineHistoryPull(edge: .older)
    @State private var olderPromptVisible = false
    @State private var olderLoadRequest: Int?
    @State private var latestPromptVisible = false
    @State private var latestLoadRequest: Int?
    @State private var nativePhase = TimelineScrollState.Phase.idle
    /// The return pill would sit on top of the keyboard while typing.
    @State private var keyboardIsVisible = false
    @State private var readingWidth: CGFloat = 0
    @State private var restoredWidth: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarDrawerIsTransitioning) private var sidebarIsTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var sidebarObscuresDetail
    @Environment(\.dismissChatKeyboard) private var dismissKeyboard
    @ScaledMetric(relativeTo: .caption) private var returnPillHeight: CGFloat = 32
#if DEBUG
    private static let drawerLayoutLog = Logger(subsystem: "agents.anywhere", category: "drawer-layout")
#endif

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
    private var viewport: TimelineViewport { viewportSample.value ?? scrolling.viewport }
    private var navigationIsSuspended: Bool { sidebarIsTransitioning || sidebarObscuresDetail }
    var body: some View {
        // A sibling overlay receives taps independently of the scroll view's
        // deceleration recognizer. The explicit return intent survives its callbacks.
        ZStack(alignment: .bottom) {
            ScrollView {
                ChatTimelineContent(model: model, onAttachment: onAttachment, onFile: onFile,
                    latestPullReady: latestPull.isReady, isLoadingLatest: latestLoadRequest != nil,
                    olderPullReady: olderPull.isReady, isLoadingOlder: olderLoadRequest != nil,
                    keepsOlderPrompt: hasRequestedOlder, historyAnchor: historyPosition?.origin,
                    onLoadOlder: loadOlder, onLoadLatest: loadLatest,
                    onHistoryLayout: historyDidLayOut,
                    onPromptVisibility: { latestPromptVisible = $0 },
                    onOlderPromptVisibility: { olderPromptVisible = $0 },
                    onTailVisibility: { region, visible in scrolling.tailVisibilityChanged(region, visible: visible) })
                    .equatable()
                    .background { ChatPageScrollEdge() }
                    .environment(\.timelineReadingWidth, readingWidth)
                    .environment(\.timelineReadingMeasurement) { id, frame, width, paragraph in
                        model.session.readingAnchor.measure(id: id, y: frame.minY, height: frame.height,
                            width: width, isParagraph: paragraph)
                    }
                    .environment(\.userMessageDisclosureChanged) { key, collapsed in
                        scrolling.browseHistory()
                        historyPosition?.cancelRestoration()
                        guard collapsed, let target = model.timeline.disclosureTarget(for: key) else { return }
                        position.scrollTo(id: target, anchor: .top)
                    }
            }
            .scrollPosition($position)
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { readingWidth = $0 }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .allowsHitTesting(model.isOpeningReady)
            .accessibilityHidden(!model.isOpeningReady)
            .onScrollPhaseChange { _, phase, context in
                // A phase callback carries a newer authoritative sample.
                viewportUpdates.cancel()
                let mapped: TimelineScrollState.Phase
                switch phase {
                case .idle: mapped = .idle
                case .tracking: mapped = .tracking
                case .interacting: mapped = .interacting
                case .decelerating: mapped = .decelerating
                case .animating: mapped = .animating
                @unknown default: mapped = .idle
                }
                let current = TimelineViewport(geometry: context.geometry)
                let wasInteracting = scrolling.phase == .interacting
                viewportSample.value = current
                scrolling.geometryChanged(current)
                nativePhase = mapped
                // The drawer owns horizontal navigation. Do not interpret its
                // interrupted scroll callbacks as a fresh vertical reading intent.
                if navigationIsSuspended { return }
                if scrolling.phaseChanged(mapped, viewport: current) {
                    // Release ScrollPosition's persistent edge target as soon
                    // as the user takes over, including interrupted animations.
                    releaseScrollPosition()
                    historyPosition?.cancelRestoration()
                    olderPull.begin(at: current, promptVisible: olderPromptVisible,
                        canLoad: model.session.hasOlderItems && !model.session.isLoadingHistory && olderLoadRequest == nil && latestLoadRequest == nil)
                    latestPull.begin(at: current, promptVisible: latestPromptVisible,
                        canLoad: model.session.hasNewerItems && !model.session.isLoadingHistory && latestLoadRequest == nil && olderLoadRequest == nil)
                }
                if mapped == .interacting { latestPull.update(current); olderPull.update(current) }
                if mapped == .idle || mapped == .decelerating {
                    let shouldLoadLatest = latestPull.end(), shouldLoadOlder = olderPull.end()
                    if wasInteracting {
                        if shouldLoadOlder { loadOlder() }
                        else if shouldLoadLatest { loadLatest() }
                    }
                } else if mapped == .animating { latestPull.cancel(); olderPull.cancel() }
            }
            .onScrollGeometryChange(for: TimelineViewport.self) { geometry in
                TimelineViewport(geometry: geometry)
            } action: { previous, value in
#if DEBUG
                // A device recording cannot distinguish a changed native
                // offset from an upstream reflow. Record only vertical changes
                // during drawer navigation, without logging message contents.
                if ChatLayoutDiagnostics.isEnabled, navigationIsSuspended,
                   abs(value.contentHeight - previous.contentHeight) > 1
                    || abs(value.visibleHeight - previous.visibleHeight) > 1
                    || abs(value.offsetY - previous.offsetY) > 1 {
                    Self.drawerLayoutLog.debug("Drawer geometry: content \(previous.contentHeight, privacy: .public) -> \(value.contentHeight, privacy: .public), viewport \(previous.visibleHeight, privacy: .public) -> \(value.visibleHeight, privacy: .public), offset \(previous.offsetY, privacy: .public) -> \(value.offsetY, privacy: .public)")
                }
#endif
                viewportUpdates.submit(value) { value in
                    // Offset samples are needed for restoration, but do not change
                    // the rendered page. Publish only dimensions used by following.
                    viewportSample.value = value
                    let previous = scrolling.viewport
                    if previous.contentHeight != value.contentHeight || previous.visibleHeight != value.visibleHeight
                        || previous.topInset != value.topInset {
                        scrolling.geometryChanged(value)
                    }
                    if !navigationIsSuspended && scrolling.phase == .interacting {
                        var latest = latestPull, older = olderPull
                        latest.update(value); older.update(value)
                        if latest != latestPull { latestPull = latest }
                        if older != olderPull { olderPull = older }
                    }
                    captureReadingPosition(value)
                }
            }
            .onChange(of: navigationIsSuspended, initial: true) { _, suspended in
                viewportUpdates.cancel()
                scrolling.setNavigationSuspended(suspended)
                if suspended {
                    releaseScrollPosition()
                    latestPull.cancel(); olderPull.cancel()
                } else {
                    scrolling.phaseChanged(nativePhase, viewport: viewport)
                    if let historyLayout { historyDidLayOut(historyLayout) }
                }
            }
            .onChange(of: model.session.pendingMessages.last?.id) { _, id in
                if model.isOpeningReady, id != nil && !hasInteractions { scrolling.requestBottom() }
            }
            .onChange(of: model.responseRevision) { _, _ in
                if model.isOpeningReady { scrolling.requestBottom() }
            }
            .onChange(of: hasInteractions, initial: true) { _, presented in
                scrolling.setInteractionPresented(presented)
            }
            .onChange(of: model.isOpeningReady, initial: true) { _, ready in
                if ready {
                    scrolling.open(interactionPresented: hasInteractions)
                    if model.session.readingAnchor.anchor != nil { scrolling.browseHistory() }
                }
            }
            .task(id: ReadingRestoration(width: readingWidth, ready: model.isOpeningReady)) {
                guard model.isOpeningReady, readingWidth > 0 else { return }
                let width = readingWidth
                let store = model.session.readingAnchor
                let anchor = store.anchor
                let generation = scrolling.navigationGeneration
                if let anchor {
                    if store.target(for: anchor, width: width) == nil {
                        let rowID = anchor.id.components(separatedBy: ":block:")[0]
                        let groups = TimelineGrouping.groups(model.timeline.rows,
                            interactionTargets: Set(model.session.notices.notices.filter { $0.isVisible && $0.notice.type == "notification" }.compactMap(\.timelineTargetID)))
                        let entries = TimelineRenderEntry.build(groups: groups)
                        let target = entries.contains { $0.id == anchor.id } ? anchor.id
                            : entries.first { $0.group.rows.contains { $0.id == rowID } }?.id ?? rowID
                        position.scrollTo(id: target, anchor: .top)
                    }
                    // Content measurements arrive after width/size-class changes.
                    // A new gesture invalidates the pending correction immediately.
                    var lastTarget: CGFloat?
                    for _ in 0..<12 {
                        do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
                        guard !Task.isCancelled, scrolling.navigationGeneration == generation else { break }
                        if let y = store.target(for: anchor, width: width) {
                            if let lastTarget, abs(y - lastTarget) <= 0.5 { continue }
                            lastTarget = y
                            var transaction = Transaction(animation: nil)
                            transaction.disablesAnimations = true
                            withTransaction(transaction) { position.scrollTo(y: max(-viewport.topInset, y - viewport.topInset)) }
                        }
                    }
                    releaseScrollPosition()
                }
                restoredWidth = width
            }
            .onChange(of: model.timeline.rows.map(\.id)) { _, ids in
                model.session.readingAnchor.retain(rowIDs: Set(ids))
            }
            .onChange(of: scrolling.navigationGeneration) { _, _ in
                releaseScrollPosition()
            }
            .task(id: scrolling.pendingBottomRequest) {
                guard let request = scrolling.pendingBottomRequest, !navigationIsSuspended else { return }
                // Coalesce actual layout changes. Scrolling through the same
                // layout cannot restart this animation on every offset callback.
                do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
                guard !Task.isCancelled, !navigationIsSuspended, let command = scrolling.begin(request) else { return }
                scrollToBottom(command)
            }
            .task(id: UserScrollSettlement(needed: scrolling.needsUserScrollSettlement,
                tail: scrolling.tail, generation: scrolling.navigationGeneration)) {
                guard scrolling.needsUserScrollSettlement else { return }
                // Reconcile visibility after the native phase callback. This
                // never holds opening behind a spinner or repeats a scroll.
                do { try await Task.sleep(for: .milliseconds(64)) } catch { return }
                guard !Task.isCancelled else { return }
                scrolling.settleUserScroll()
            }
            .task(id: olderLoadRequest) {
                guard let request = olderLoadRequest else { return }
                await model.session.loadOlder()
                guard !Task.isCancelled, historyPosition?.id == request else { return }
                if !model.session.isValid { historyPosition = nil; olderLoadRequest = nil; return }
                historyPosition?.receivedPage(firstRowID: model.session.timeline.first { $0.value.isVisibleInChat }?.id)
            }
            .task(id: HistorySettlement(id: historyPosition?.id, ready: historyPosition?.isReadyToFinish == true,
                offset: historyPosition?.restoredOffset)) {
                guard let request = historyPosition?.id, historyPosition?.isReadyToFinish == true else { return }
                // Let the point correction reach native layout before releasing
                // its target or ending the spinner. A new measurement restarts this.
                do { try await Task.sleep(for: .milliseconds(64)) } catch { return }
                guard !Task.isCancelled, historyPosition?.id == request else { return }
                if scrolling.navigationGeneration == request, historyPosition?.restoredOffset != nil {
                    position.isPositionedByUser = true
                }
                historyPosition = nil; olderLoadRequest = nil
            }
            .task(id: latestLoadRequest) {
                guard let generation = latestLoadRequest else { return }
                await model.session.loadLatest()
                guard !Task.isCancelled else { return }
                // A drag during the fetch must not be undone when it finishes.
                if scrolling.navigationGeneration == generation { scrolling.requestBottom() }
                latestLoadRequest = nil
            }
            if !keyboardIsVisible, scrolling.showsBottomButton() {
                Button {
                    latestPull.cancel(); olderPull.cancel()
                    historyPosition?.cancelRestoration()
                    scrolling.requestBottom()
                } label: {
                    Label(String(localized: "到底部"), appSymbol: "arrow.down").font(.caption.weight(.medium)).foregroundStyle(.primary)
                        .padding(.horizontal, 12).frame(height: returnPillHeight)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("chat.timeline.bottom")
                .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Background receives only unhandled taps, leaving links, selection and
        // controls in the foreground with their original gestures.
        .background { Color.clear.contentShape(Rectangle()).onTapGesture { dismissKeyboard() } }
        .traceChatLayout("timeline-viewport")
        .onDisappear { viewportUpdates.cancel(); historyUpdates.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
        }
    }
    private func loadOlder() {
        guard model.session.isValid, model.session.hasOlderItems,
              !model.session.isLoadingHistory, olderLoadRequest == nil, latestLoadRequest == nil else { return }
        olderPull.cancel(); latestPull.cancel()
        scrolling.browseHistory()
        position.isPositionedByUser = true
        let interactionTargets = Set(model.session.notices.notices.filter { $0.isVisible && $0.notice.type == "notification" }.compactMap(\.timelineTargetID))
        let groups = TimelineGrouping.groups(model.timeline.rows, interactionTargets: interactionTargets)
        let layout = model.timeline.rows.first.flatMap { first in
            model.session.readingAnchor.historyLayout(firstRowID: first.id, entries: TimelineRenderEntry.build(groups: groups),
                top: viewport.offsetY + viewport.topInset, width: readingWidth)
        }
        historyPosition = TimelineHistoryPosition(id: scrolling.navigationGeneration, layout: layout,
            offsetY: viewport.offsetY, topInset: viewport.topInset)
        hasRequestedOlder = true
        olderLoadRequest = scrolling.navigationGeneration
    }
    private func captureReadingPosition(_ value: TimelineViewport) {
        guard model.isOpeningReady, readingWidth > 0, restoredWidth == readingWidth,
              abs(value.containerWidth - readingWidth) < 1,
              !navigationIsSuspended else { return }
        model.session.readingAnchor.capture(top: value.offsetY + value.topInset, width: readingWidth,
            following: scrolling.mode != .reading)
    }
    private struct ReadingRestoration: Equatable {
        let width: CGFloat
        let ready: Bool
    }
    private func loadLatest() {
        guard model.session.isValid, model.session.hasNewerItems,
              !model.session.isLoadingHistory, latestLoadRequest == nil, olderLoadRequest == nil else { return }
        olderPull.cancel(); latestPull.cancel()
        historyPosition?.cancelRestoration()
        scrolling.requestBottom()
        latestLoadRequest = scrolling.navigationGeneration
    }
    private func scrollToBottom(_ command: TimelineScrollState.BottomCommand) {
        withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 1, blendDuration: 0.12),
            completionCriteria: .removed) {
            // Let the scroll view resolve its own safe-area/inset coordinate
            // system. The edge target is released when this animation finishes
            // or as soon as a gesture/drawer/approval cancels the command.
            position.scrollTo(edge: .bottom)
        } completion: {
            if scrolling.complete(command) { releaseScrollPosition() }
        }
    }
    private func releaseScrollPosition() {
        guard position.edge != nil || position.point != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.isPositionedByUser = true }
    }
    private func historyDidLayOut(_ layout: TimelineHistoryLayout) {
        historyUpdates.submit(layout) { layout in
            if historyLayout != layout { historyLayout = layout }
            guard !navigationIsSuspended, var restoration = historyPosition else { return }
            let offset = restoration.laidOut(layout, generation: scrolling.navigationGeneration)
            if historyPosition != restoration { historyPosition = restoration }
            guard let offset else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(y: offset) }
        }
    }
    private struct HistorySettlement: Equatable {
        let id: Int?
        let ready: Bool
        let offset: CGFloat?
    }
    private struct UserScrollSettlement: Equatable {
        let needed: Bool
        let tail: TimelineTailVisibility
        let generation: Int
    }
}

/// Keep the latest measurement without publishing View state inside a layout
/// callback. One main-queue delivery handles a burst; removal invalidates it.
@MainActor private final class ChatLayoutUpdate<Value> {
    private var pending: (() -> Void)?
    private var scheduled = false
    private var generation = 0

    func submit(_ value: Value, apply: @escaping (Value) -> Void) {
        pending = { apply(value) }
        guard !scheduled else { return }
        scheduled = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            let update = self.pending
            self.pending = nil
            self.scheduled = false
            update?()
        }
    }

    func cancel() {
        generation &+= 1
        pending = nil
        scheduled = false
    }
}

private struct ChatTimelineContent: View, Equatable {
    @Environment(\.dismissChatKeyboard) private var dismissKeyboard
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void
    let latestPullReady: Bool
    let isLoadingLatest: Bool
    let olderPullReady: Bool
    let isLoadingOlder: Bool
    let keepsOlderPrompt: Bool
    let historyAnchor: TimelineHistoryLayout?
    let onLoadOlder: () -> Void
    let onLoadLatest: () -> Void
    let onHistoryLayout: (TimelineHistoryLayout) -> Void
    let onPromptVisibility: (Bool) -> Void
    let onOlderPromptVisibility: (Bool) -> Void
    let onTailVisibility: (TimelineTailVisibility.Region, Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.latestPullReady == rhs.latestPullReady && lhs.isLoadingLatest == rhs.isLoadingLatest
            && lhs.olderPullReady == rhs.olderPullReady && lhs.isLoadingOlder == rhs.isLoadingOlder
            && lhs.keepsOlderPrompt == rhs.keepsOlderPrompt && lhs.historyAnchor == rhs.historyAnchor
    }
    var body: some View {
        // Interactions have one shared pager above the composer, regardless of
        // blocking scope or timeline target. Only notifications remain inline.
        let visibleNotices = model.session.notices.notices.filter { $0.isVisible && $0.notice.type == "notification" }
        let groups = TimelineGrouping.groups(model.timeline.rows, interactionTargets: Set(visibleNotices.compactMap(\.timelineTargetID)))
        // Resolve notice targets once per body instead of once per row.
        let rowIDs = Set(model.timeline.rows.map(\.id))
        let noticesByTarget = Dictionary(grouping: visibleNotices.filter { $0.timelineTargetID != nil }) { $0.timelineTargetID! }
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: model.isRunning || model.session.hasNewerItems,
            hasPendingUserMessage: !model.session.hasNewerItems && (!model.timeline.pendingMessages.isEmpty || !model.session.pendingMessages.isEmpty))
        // Prefer a message whose start cannot move into a prefixed tool group.
        // For an all-tools page, retain the existing group's trailing edge.
        let entries = TimelineRenderEntry.build(groups: groups)
        let preparations = groups.compactMap { group -> ChatMarkdownView.Preparation? in
            guard group.kind == .single, group.rows.count == 1,
                  let row = group.rows.first, row.usesBlockTimeline else { return nil }
            return ChatMarkdownView.Preparation(row)
        }
        let anchorEntry = readingEntry(in: entries)
        let anchorEdge: TimelineHistoryLayout.Edge = historyAnchor?.edge
            ?? (anchorEntry?.group.rows.first?.structure.groupKind == .single ? .top : .bottom)
        LazyVStack(alignment: .leading, spacing: 0) {
            if model.session.hasOlderItems || keepsOlderPrompt { olderPrompt }
            ForEach(entries) { entry in
                TimelineEntryView(entry: entry, model: model, onAttachment: onAttachment, onFile: onFile,
                    turnAction: actions[entry.group.id],
                    inlineNotices: entry.group.rows.flatMap { noticesByTarget[$0.id] ?? [] })
                    .id(entry.id)
                    .modifier(TimelineReadingMeasurement(id: entry.id, isParagraph: entry.isParagraph))
                    .background {
                        if entry.id == anchorEntry?.id, let firstRowID = model.timeline.rows.first?.id {
                            Color.clear.onGeometryChange(for: TimelineHistoryLayout.self) { geometry in
                                let frame = geometry.frame(in: .named("chat.timeline.content"))
                                return TimelineHistoryLayout(firstRowID: firstRowID,
                                    anchorRowID: historyAnchor?.anchorRowID ?? entry.id, edge: anchorEdge,
                                    y: anchorEdge == .top ? frame.minY : frame.maxY)
                            } action: { onHistoryLayout($0) }
                        }
                    }
                    .padding(.bottom, entry.isParagraph ? 12 : 20)
            }
            ForEach(visibleNotices.filter { notice in
                notice.timelineTargetID.map { !rowIDs.contains($0) } ?? true
            }) { item in SessionInteractionCard(item: item, chat: model).padding(.bottom, 20) }
            ForEach(model.timeline.pendingMessages) { pending in
                PendingMessageRow(pending: pending, chat: model, onAttachment: onAttachment,
                    onDismiss: { model.session.dismissPendingMessage(id: pending.id) })
                    .id(pending.id)
                    .padding(.bottom, 20)
            }
            if model.session.hasNewerItems { newerPrompt }
            timelineTail
        }
        .task(id: preparations) {
            // Prefer the latest reply and bound parser work even in a history
            // window containing many long messages.
            for preparation in preparations.reversed() {
                guard !Task.isCancelled else { return }
                await ChatMarkdownView.prepare(preparation)
            }
        }
        .scrollTargetLayout()
        .modifier(ChatPageContentColumn(horizontalInset: nil))
        .coordinateSpace(name: "chat.timeline.content")
        .traceChatLayout("timeline-content", state: "groups=\(groups.count), footers=\(actions.count), running=\(model.isRunning)")
    }

    private func readingEntry(in entries: [TimelineRenderEntry]) -> TimelineRenderEntry? {
        if let anchor = historyAnchor {
            if let exact = entries.first(where: { $0.id == anchor.anchorRowID }) { return exact }
            if let group = entries.first(where: { $0.group.rows.contains { $0.id == anchor.anchorRowID } }) { return group }
        }
        if let id = model.session.readingAnchor.anchor?.id {
            if let exact = entries.first(where: { $0.id == id }) { return exact }
            let rowID = String(id.components(separatedBy: ":block:")[0])
            if let group = entries.first(where: { $0.group.rows.contains { $0.id == rowID } }) { return group }
        }
        return entries.first { $0.group.rows.first?.structure.groupKind == .single } ?? entries.last
    }

    private var olderPrompt: some View {
        Group {
            if isLoadingOlder {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                    Text(String(localized: "正在加载较早的消息…"))
                }.accessibilityElement(children: .combine)
            } else if model.session.hasOlderItems {
                Button(action: onLoadOlder) {
                    Text(olderPullReady ? String(localized: "松开加载较早的消息") : String(localized: "加载较早的消息"))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }.disabled(model.session.isLoadingHistory || isLoadingLatest)
            } else {
                // Retain the prompt's footprint on the final page; removing
                // it after restoring would move the reader by another row.
                Text(String(localized: "已到达会话开头")).foregroundStyle(.secondary)
            }
        }
        .font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
        .onScrollVisibilityChange(threshold: 0.9) { onOlderPromptVisibility($0) }
        .padding(.bottom, 20)
    }

    private var newerPrompt: some View {
        Button(action: onLoadLatest) {
            Group {
                if isLoadingLatest { ProgressView(String(localized: "正在加载更新的记录…")) }
                else { Text(latestPullReady ? String(localized: "松开加载更新的记录") : String(localized: "继续上拉加载更新的记录")) }
            }.font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(model.session.isLoadingHistory || isLoadingLatest || isLoadingOlder)
        .onScrollVisibilityChange { onPromptVisibility($0) }
        .padding(.bottom, 20)
    }

    private var timelineTail: some View {
        // Constant breathing room: status text and card counts cannot
        // change this spacer or create a spurious follow request.
        Group {
            if let text = model.sendingPlaceholder {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else { Color.clear }
        }.frame(height: 32)
            .contentShape(Rectangle())
            .onTapGesture { dismissKeyboard() }
            .traceChatLayout("tail-spacer")
            .overlay(alignment: .bottom) {
                Color.clear.frame(height: 96)
                    .onScrollVisibilityChange(threshold: 0.01) { onTailVisibility(.near, $0) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                Color.clear.frame(height: 2)
                    .onScrollVisibilityChange(threshold: 0.5) { onTailVisibility(.end, $0) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .id("tail")
    }

}

private struct TimelineEntryView: View {
    let entry: TimelineRenderEntry
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void
    let turnAction: TimelineTurnAction?
    let inlineNotices: [SessionNoticeModel]

    var body: some View {
        switch entry.content {
        case let .markdown(block):
            if let row = entry.group.rows.first {
                MarkdownBlockView(block: block, isStreaming: row.isRevealing,
                    isTail: block.id == row.markdown.blocks.last?.id,
                    revealDeadline: row.markdown.deadlines[block.id] ?? .distantPast)
                    .equatable()
                    .environment(\.chatLayoutTraceOwner, row.id)
            }
        case .group, .messageTail:
            SessionTimelineGroupView(group: entry.group, chat: model,
                onAttachment: onAttachment, onFile: onFile, turnAction: turnAction,
                inlineNotices: inlineNotices, omitsAssistantText: entry.group.rows.first?.usesBlockTimeline == true)
                .equatable()
        }
    }
}

private extension TimelineViewport {
    init(geometry: ScrollGeometry) {
        self.init(contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height,
            topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom, offsetY: geometry.contentOffset.y,
            containerWidth: geometry.containerSize.width)
    }
}

/// Native offset storage deliberately does not invalidate the SwiftUI view tree.
@MainActor private final class ChatViewportSample {
    var value: TimelineViewport?
}
