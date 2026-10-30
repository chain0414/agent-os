import Foundation

/// Treat an entire HTTP(S) URL in inline code as a web link, matching native
/// runtime clients without interpreting commands or fenced code as navigation.
nonisolated enum InlineCodeWebLink {
    static func url(_ text: String) -> URL? {
        guard !text.isEmpty, !text.contains(where: \.isWhitespace),
              let value = URL(string: text, encodingInvalidCharacters: false),
              ["http", "https"].contains(value.scheme?.lowercased() ?? ""),
              let host = value.host, !host.isEmpty else { return nil }
        return value
    }

    static func enrich(_ source: AttributedString) -> AttributedString {
        var result = source
        for run in source.runs {
            guard run.link == nil, run.inlinePresentationIntent?.contains(.code) == true else { continue }
            let block = run.presentationIntent?.components.contains {
                if case .codeBlock = $0.kind { return true }
                return false
            } == true
            guard !block, let destination = url(String(source[run.range].characters)) else { continue }
            result[run.range].link = destination
        }
        return result
    }
}
