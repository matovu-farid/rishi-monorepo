import Testing
import Foundation
@testable import RishiCore

@Suite("ReadAloudParagraphLocator")
struct ReadAloudParagraphLocatorTests {

    @Test("Finds the range of an exact paragraph substring")
    func findsExactRange() throws {
        let page = "First paragraph.\n\nSecond paragraph here.\n\nThird."
        let range = try #require(
            ReadAloudParagraphLocator.range(of: "Second paragraph here.", in: page)
        )
        #expect(String(page[range]) == "Second paragraph here.")
    }

    @Test("Matches a chunker paragraph whose whitespace was collapsed")
    func matchesCollapsedWhitespace() throws {
        // ParagraphChunker collapses internal runs of whitespace to a single
        // space; the page string still carries the original newlines/spaces.
        let page = "Alice  was\nbeginning to   get\nvery tired."
        let paragraph = "Alice was beginning to get very tired."
        let range = try #require(
            ReadAloudParagraphLocator.range(of: paragraph, in: page)
        )
        let matched = String(page[range])
        // The matched slice spans the whole original passage (with its
        // original whitespace), normalising to the requested paragraph.
        #expect(
            matched.replacingOccurrences(
                of: "\\s+", with: " ", options: .regularExpression
            ) == paragraph
        )
    }

    @Test("Returns nil for a paragraph not present on the page")
    func returnsNilWhenAbsent() {
        let page = "Only this text exists."
        #expect(ReadAloudParagraphLocator.range(of: "Missing passage", in: page) == nil)
    }

    @Test("Returns nil for empty inputs")
    func returnsNilForEmpty() {
        #expect(ReadAloudParagraphLocator.range(of: "", in: "non-empty") == nil)
        #expect(ReadAloudParagraphLocator.range(of: "x", in: "") == nil)
    }

    @Test("Finds the first occurrence when a paragraph repeats")
    func findsFirstOccurrence() {
        let page = "repeat. middle. repeat."
        let range = ReadAloudParagraphLocator.range(of: "repeat.", in: page)
        #expect(range?.lowerBound == page.startIndex)
    }
}
