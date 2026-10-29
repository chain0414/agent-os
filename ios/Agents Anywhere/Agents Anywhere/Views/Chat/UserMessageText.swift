import SwiftUI
import UIKit
import CoreText

extension EnvironmentValues {
    @Entry var userMessageDisclosureChanged: (String, Bool) -> Void = { _, _ in }
    @Entry var dismissChatKeyboard: () -> Void = {}
}

struct UserMessageText: View {
    let text: String
    let availableWidth: CGFloat
    let expansion: UserMessageExpansionStore
    let messageKey: String
    @State private var previewCache = PreviewCache()
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.userMessageDisclosureChanged) private var disclosureChanged

    private var request: PreviewRequest {
        let font = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicType.uiContentSizeCategory))
        return .init(text: text, width: max(1, availableWidth), fontName: font.fontName, fontSize: font.pointSize,
            level: expansion.level(messageKey), dynamicType: dynamicType)
    }

    var body: some View {
        let preview = previewCache.value(for: request)
        VStack(alignment: .leading, spacing: 4) {
            ChatSelectableText(text: preview.text).font(.body)
            if preview.hasMore || expansion.level(messageKey) != .collapsed {
                HStack(spacing: 12) {
                    if preview.hasMore {
                        Button(expansion.level(messageKey) == .collapsed ? String(localized: "展开更多") : String(localized: "展开全文")) {
                            disclosureChanged(messageKey, false)
                            expansion.expand(messageKey)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                        .accessibilityIdentifier("chat.message.expand")
                    }
                    if expansion.level(messageKey) != .collapsed {
                        Button(String(localized: "收起")) {
                            disclosureChanged(messageKey, true)
                            expansion.collapse(messageKey)
                        }
                        .frame(minHeight: 44).contentShape(Rectangle())
                        .accessibilityIdentifier("chat.message.collapse")
                    }
                    Button {
                        UIPasteboard.general.string = text
                    } label: { AppSymbol("document.on.document").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel(String(localized: "复制全文"))
                        .accessibilityIdentifier("chat.message.copyFull")
                }
                .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
    }

    /// Width/level changes synchronously produce a bounded preview, so the first
    /// layout never mounts an empty bubble and then shifts the reading position.
    private final class PreviewCache {
        private var cached: (PreviewRequest, UserMessagePreview)?
        func value(for request: PreviewRequest) -> UserMessagePreview {
            if let cached, cached.0 == request { return cached.1 }
            let font = CTFontCreateWithName(request.fontName as CFString, request.fontSize, nil)
            let result = UserMessagePreview.make(request.text, width: request.width, font: font, lineLimit: request.level.lineLimit)
            cached = (request, result)
            return result
        }
    }

    private struct PreviewRequest: Equatable {
        let text: String
        let width: CGFloat
        let fontName: String
        let fontSize: CGFloat
        let level: UserMessageExpansionStore.Level
        let dynamicType: DynamicTypeSize
    }
}

private extension DynamicTypeSize {
    var uiContentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
