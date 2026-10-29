import Foundation
import Testing
@testable import ClientCore

@Suite struct InlineCodeWebLinkTests {
    @Test func exactCodeURLBecomesLinkWithoutChangingTextOrCodeAppearance() throws {
        let raw = "页面：`http://127.0.0.1:4315/reports/daily-2026-10-29`。"
        let source = try AttributedString(markdown: raw)
        let result = InlineCodeWebLink.enrich(source)
        let linked = try #require(result.runs.first(where: { $0.link != nil }))
        #expect(linked.link?.absoluteString == "http://127.0.0.1:4315/reports/daily-2026-10-29")
        #expect(linked.inlinePresentationIntent?.contains(.code) == true)
        #expect(String(result.characters) == String(source.characters))
    }
    @Test func normalMarkdownLinkKeepsItsDisplayNameAndDestination() throws {
        let source = try AttributedString(markdown: "[日报](https://example.test/report)")
        let result = InlineCodeWebLink.enrich(source)
        #expect(String(result.characters) == "日报")
        #expect(result.runs.first?.link == URL(string: "https://example.test/report"))
    }
    @Test func fencedCodeAndCommandsRemainCode() throws {
        for raw in ["```\nhttps://example.test/report\n```", "`curl https://example.test/report`", "`https://example.test/report --flag`"] {
            let result = InlineCodeWebLink.enrich(try AttributedString(markdown: raw))
            #expect(result.runs.allSatisfy { $0.link == nil })
        }
    }
    @Test func onlyCompleteHTTPOrHTTPSURLsAreEligible() {
        for raw in ["https://example.test/a?x=1#section", "http://localhost:4315/reports/daily", "HTTPS://example.test/a"] {
            #expect(InlineCodeWebLink.url(raw) != nil)
        }
        for raw in ["javascript:alert(1)", "file:///work/a.md", "aa-workspace-file://preview?path=a", "mailto:a@example.test", "https://", "//example.test/a", "example.test/a", " https://example.test/a", "https://example.test/%xx", "https://example.test/a\nb"] {
            #expect(InlineCodeWebLink.url(raw) == nil)
        }
    }
    @Test func existingLinkAndLocalFileReferencesAreNotRewritten() throws {
        var source = try AttributedString(markdown: "`src/App.swift:20` and `https://example.test/a`")
        let code = try #require(source.runs.first(where: { String(source[$0.range].characters).contains("https://") }))
        let existing = URL(string: "https://existing.test/target")!
        source[code.range].link = existing
        let result = InlineCodeWebLink.enrich(source)
        #expect(result.runs.contains(where: { $0.link == existing }))
        #expect(result.runs.filter { $0.link != nil }.count == 1)
    }
}
