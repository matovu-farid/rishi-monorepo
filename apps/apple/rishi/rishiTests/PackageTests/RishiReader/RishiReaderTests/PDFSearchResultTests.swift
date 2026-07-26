@testable import rishi
import Foundation
import Testing


/// Phase 37 Plan 37-04 — pure-logic coverage for the PDF search-result row
/// model and its snippet mapper. This is the one host-testable seam of the
/// PDF search feature: the live PDFKit `beginFindString` scan + jump/highlight
/// are verified by the integrated `xcodebuild iPhone 17 + Mac Catalyst` gate
/// (RishiReader cannot `swift test` on the host because of its Readium floor).
@Suite("PDFSearchResult")
struct PDFSearchResultTests {

    @Test("Short match strings are preserved verbatim by the snippet mapper")
    func shortSnippetPreserved() {
        let raw = "It was the best of times"
        let snippet = PDFSearchResult.snippet(from: raw)
        #expect(snippet == raw)
    }

    @Test("Long match strings clamp to the default maxLength with an ellipsis")
    func longSnippetClamped() {
        let raw = String(repeating: "a", count: 500)
        let snippet = PDFSearchResult.snippet(from: raw)
        #expect(snippet.count <= 121) // 120 chars + a single ellipsis character
        #expect(snippet.hasSuffix("\u{2026}"))
        #expect(snippet.hasPrefix("aaaa"))
    }

    @Test("Snippet mapper trims surrounding whitespace and newlines")
    func snippetTrimmed() {
        let raw = "\n   hello world  \n"
        let snippet = PDFSearchResult.snippet(from: raw)
        #expect(snippet == "hello world")
    }

    @Test("Snippet mapper honours a custom maxLength")
    func snippetCustomMaxLength() {
        let raw = "abcdefghij"
        let snippet = PDFSearchResult.snippet(from: raw, maxLength: 4)
        #expect(snippet == "abcd\u{2026}")
    }

    @Test("Whitespace-only input collapses to an empty snippet")
    func snippetWhitespaceOnly() {
        #expect(PDFSearchResult.snippet(from: "   \n\t ") == "")
    }

    @Test("Two results with distinct ids are not equal even at the same page")
    func distinctIdentityInequality() {
        let a = PDFSearchResult(page: 3, snippet: "match")
        let b = PDFSearchResult(page: 3, snippet: "match")
        #expect(a != b)
        #expect(a.id != b.id)
    }

    @Test("A result is equal to itself and stable in a Set")
    func equalityAndHashing() {
        let result = PDFSearchResult(id: UUID(), page: 7, snippet: "needle")
        #expect(result == result)
        let set: Set<PDFSearchResult> = [result, result]
        #expect(set.count == 1)
    }

    @Test("page is stored 0-based as supplied by document.index(for:)")
    func zeroBasedPage() {
        let result = PDFSearchResult(page: 0, snippet: "first page")
        #expect(result.page == 0)
    }
}
