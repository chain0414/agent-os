import Foundation
import CoreText
import Testing
@testable import ClientCore

@Suite @MainActor struct UserMessagePreviewTests {
    @Test func pendingDisclosureTargetsItsOwnBubbleBeforeServerEcho() {
        let presentation = SessionTimelinePresentation()
        let pending = V2PendingMessage(id: "pending-1", content: "Long draft", attachmentIDs: [])
        presentation.presentOpening([], pendingMessages: [pending])
        #expect(presentation.disclosureTarget(for: "client:pending-1") == "pending-1")
        #expect(presentation.disclosureTarget(for: "client:missing") == nil)
    }
    private let font = CTFontCreateWithName("Helvetica" as CFString, 17, nil)

    @Test func shortTextHasNoDisclosureAndRetainsLiteralMarkup() {
        let text = "<decision>ordinary input</decision>"
        let preview = UserMessagePreview.make(text, width: 400, font: font, lineLimit: 8)
        #expect(preview.text == text && !preview.hasMore)
    }

    @Test func previewIncludesOnlyVisibleLinesAndSupportsNextStage() {
        let text = (1...40).map { "line \($0)" }.joined(separator: "\n")
        let collapsed = UserMessagePreview.make(text, width: 300, font: font, lineLimit: 8)
        let expanded = UserMessagePreview.make(text, width: 300, font: font, lineLimit: 24)
        #expect(collapsed.hasMore && expanded.hasMore)
        #expect(collapsed.text.split(separator: "\n").count == 8)
        #expect(expanded.text.split(separator: "\n").count == 24)
        #expect(!collapsed.text.contains("line 9"))
        #expect(UserMessagePreview.make(text, width: 300, font: font, lineLimit: nil).text == text)
    }

    @Test func wrappingCountsDisplayedLinesAndPreservesUnicode() {
        let text = String(repeating: "中文👨‍👩‍👧‍👦é测试文字", count: 100)
        let narrow = UserMessagePreview.make(text, width: 80, font: font, lineLimit: 8)
        let wide = UserMessagePreview.make(text, width: 300, font: font, lineLimit: 8)
        #expect(narrow.hasMore && wide.hasMore)
        #expect(text.hasPrefix(narrow.text) && text.hasPrefix(wide.text))
        #expect(wide.text.count > narrow.text.count)
        #expect(!narrow.text.contains("�"))
    }

    @Test func exactLineLimitDoesNotShowAnExtraExpandButton() {
        let text = (1...8).map { "line \($0)" }.joined(separator: "\n")
        #expect(!UserMessagePreview.make(text, width: 300, font: font, lineLimit: 8).hasMore)
    }

    @Test func expansionStateSurvivesPendingEchoAndIsScopedToSessionOwner() {
        let store = UserMessageExpansionStore()
        let key = UserMessageExpansionStore.key(itemID: "pending", clientMessageID: "local-123")
        store.expand(key)
        let echo = UserMessageExpansionStore.key(itemID: "server-item", clientMessageID: "local-123")
        #expect(store.level(echo) == .more)
        store.expand(echo)
        #expect(store.level(key) == .full)
        store.collapse(echo)
        #expect(store.level(key) == .collapsed)
        #expect(UserMessageExpansionStore().level(echo) == .collapsed)
    }

    @Test func messageIDsCannotCollideWithClientMessageIDs() {
        #expect(UserMessageExpansionStore.key(itemID: "same", clientMessageID: nil)
            != UserMessageExpansionStore.key(itemID: "other", clientMessageID: "same"))
    }

    @Test func clearingSessionResetsExpansionLevels() {
        let store = UserMessageExpansionStore()
        store.expand("item:message")
        store.clear()
        #expect(store.level("item:message") == .collapsed)
    }
}
