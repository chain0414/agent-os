import SwiftUI

/// The phone drawer needs a navigation host inside its moving card. The iPad
/// detail already has the NavigationSplitView's host; nesting another stack
/// there would duplicate navigation chrome and safe-area handling.
struct ChatDetailNavigation: ViewModifier {
    let insets: EdgeInsets
    @Environment(\.sidebarDrawerPresentation) private var presentation
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        Group {
            if presentation == .drawer {
                NavigationStack { content }
                    .ignoresSafeArea(.keyboard)
                    // Preserve the drawer's stable, untransformed safe area,
                    // including keyboard avoidance. Pages add no other inset.
                    .padding(insets)
            } else {
                content
            }
        }
        .background(Color(uiColor: .systemBackground))
        .tint(AppTheme.primaryControlBackground(colorScheme))
    }
}

/// Native title/subtitle placements and toolbar items own size, spacing, glass
/// grouping and scroll-edge rendering. No header view sits in the timeline.
struct ChatPageToolbar: ViewModifier {
    let title: String
    var subtitle: String?
    var status: ChatHeaderStatus?
    var alignsTitleLeading = false
    var titleVisibility: ChatTitleVisibility? = nil
    let onMenu: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .navigationTitle(alignsTitleLeading ? "" : title)
            .navigationSubtitle(alignsTitleLeading ? "" : subtitle ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar(removing: .sidebarToggle)
            .toolbarBackground(titleVisibility == nil ? .automatic : .hidden, for: .navigationBar)
            .background {
                if let titleVisibility {
                    ChatTitleBackdrop(visibility: titleVisibility)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onMenu) { SidebarMenuIcon() }
                        .accessibilityLabel(String(localized: "打开侧栏"))
                        .accessibilityIdentifier("chat.header.sidebar")
                }
                if alignsTitleLeading {
                    // Use the title region's available width. A leading bar
                    // item is sized as a control and can collapse to its minimum
                    // width even when there is space between the buttons.
                    ToolbarItem(placement: .principal) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title).font(.headline).lineLimit(1)
                                .accessibilityIdentifier("chat.header.title")
                                .accessibilityAddTraits(.isHeader)
                            if subtitle != nil || status != nil {
                                ChatToolbarSubtitle(subtitle: subtitle, status: status, strongerContrast: titleVisibility != nil)
                                    .accessibilityIdentifier("chat.header.subtitle")
                            }
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(ChatTitleReveal(isVisible: titleVisibility?.isVisible != false,
                                                  reduceMotion: reduceMotion))
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else if subtitle != nil || status != nil {
                    ToolbarItem(placement: .subtitle) {
                        ChatToolbarSubtitle(subtitle: subtitle, status: status)
                    }
                }
            }
    }
}

enum ChatTitleTransition {
    static let duration: TimeInterval = 0.42
}

/// Animate only the title's drawing region. The top-anchored mask rolls the
/// subtitle and title upward on dismissal, then reveals them downward again;
/// the native toolbar's measured height and the reading position stay fixed.
private struct ChatTitleReveal: ViewModifier {
    let isVisible: Bool
    let reduceMotion: Bool
    @ScaledMetric(relativeTo: .headline) private var lift: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .offset(y: isVisible || reduceMotion ? 0 : -lift)
            .opacity(isVisible ? 1 : (reduceMotion ? 0 : 0.4))
            .mask(alignment: .top) {
                Rectangle().scaleEffect(x: 1, y: isVisible ? 1 : 0, anchor: .top)
            }
            .accessibilityHidden(!isVisible)
            .animation(reduceMotion ? nil : .easeInOut(duration: ChatTitleTransition.duration), value: isVisible)
    }
}

private struct ChatToolbarSubtitle: View {
    let subtitle: String?
    let status: ChatHeaderStatus?
    var strongerContrast = false
    @ScaledMetric(relativeTo: .caption) private var lineHeight: CGFloat = 16

    private var text: String {
        [subtitle, status?.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 4) {
            if let status {
                Group {
                    if status.isProgress { ProgressView().controlSize(.mini) }
                    else { AppSymbol(status.symbol, size: 12) }
                }.frame(width: lineHeight, height: lineHeight)
            }
            Text(verbatim: text).lineLimit(1)
        }
        .font(.caption).foregroundStyle(strongerContrast ? Color.primary.opacity(0.85) : Color.secondary)
        .frame(height: lineHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([subtitle, status?.detail].compactMap { $0 }.joined(separator: " · "))
    }
}

struct SidebarMenuIcon: View {
    var body: some View {
        AppSymbol("sidebar.left", size: 22).accessibilityHidden(true)
    }
}


extension EnvironmentValues {
    @Entry var chatTitleVisibility: ChatTitleVisibility? = nil
}
