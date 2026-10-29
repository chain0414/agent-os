import Foundation
import CoreText
import Observation

/// Lays out at most the requested number of lines. The hidden suffix never
/// enters Textual's layout or selection tree.
nonisolated struct UserMessagePreview: Equatable {
    let text: String
    let hasMore: Bool

    static func make(_ text: String, width: CGFloat, font: CTFont, lineLimit: Int?) -> Self {
        guard let lineLimit else { return .init(text: text, hasMore: false) }
        guard !text.isEmpty, width.isFinite, width > 0 else { return .init(text: "", hasMore: !text.isEmpty) }
        let source = text as NSString
        let attributed = NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var end = 0
        for _ in 0..<max(0, lineLimit) where end < source.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, end, Double(width))
            guard count > 0 else { break }
            end += count
        }
        guard end < source.length else { return .init(text: text, hasMore: false) }
        // Do not split a composed character if a font cannot fit one glyph.
        if end > 0 {
            let character = source.rangeOfComposedCharacterSequence(at: end)
            if character.location < end { end = character.location }
        }
        let prefix = source.substring(to: end)
            .replacingOccurrences(of: "[\\r\\n]+$", with: "", options: .regularExpression)
        return .init(text: prefix, hasMore: true)
    }
}

@MainActor final class UserMessageExpansionStore {
    enum Level: Int { case collapsed, more, full
        var lineLimit: Int? { switch self { case .collapsed: 8; case .more: 24; case .full: nil } }
    }
    @Observable fileprivate final class Entry { var level = Level.collapsed }
    private var entries: [String: Entry] = [:]
    static func key(itemID: String, clientMessageID: String?) -> String {
        clientMessageID.map { "client:\($0)" } ?? "item:\(itemID)"
    }
    private func entry(_ key: String) -> Entry {
        if let value = entries[key] { return value }
        let value = Entry(); entries[key] = value; return value
    }
    func level(_ key: String) -> Level { entry(key).level }
    func expand(_ key: String) {
        let value = entry(key)
        value.level = value.level == .collapsed ? .more : .full
    }
    func collapse(_ key: String) { entry(key).level = .collapsed }
    func clear() { entries.removeAll() }
}
