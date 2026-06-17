//
//  IndexHeaderHeuristicTests.swift
//  RishiCoreTests
//
//  Focused coverage for the indexing header heuristic extracted out of
//  ParagraphChunker in plan 34-12. Exercises `mergeShortParagraphs` directly on
//  pre-split paragraph arrays (the chunkForIndexing composition is still covered
//  by ParagraphChunkerForIndexingTests).
//

import Testing
@testable import RishiCore

@Suite("IndexHeaderHeuristic.mergeShortParagraphs")
struct IndexHeaderHeuristicTests {

    private static let minChars = IndexHeaderHeuristic.minBodyChars

    private static let longBody =
        "First body paragraph that is comfortably above the 50-character minimum threshold for body text."
    private static let secondBody =
        "Second body paragraph that is also clearly above the fifty character minimum body threshold."

    @Test("minBodyChars matches the documented electron MIN_PARAGRAPH_LENGTH")
    func minBodyCharsIsFifty() {
        #expect(IndexHeaderHeuristic.minBodyChars == 50)
    }

    @Test("empty input returns empty")
    func emptyReturnsEmpty() {
        #expect(IndexHeaderHeuristic.mergeShortParagraphs([], minChars: Self.minChars) == [])
    }

    @Test("leading short paragraph (header) is dropped")
    func leadingShortDropped() {
        let out = IndexHeaderHeuristic.mergeShortParagraphs(
            ["Chapter 1", Self.longBody],
            minChars: Self.minChars
        )
        #expect(out == [Self.longBody])
    }

    @Test("leading long paragraph is kept")
    func leadingLongKept() {
        let leading = "A long opening paragraph well past fifty characters that is definitely body text."
        let out = IndexHeaderHeuristic.mergeShortParagraphs(
            [leading, Self.secondBody],
            minChars: Self.minChars
        )
        #expect(out == [leading, Self.secondBody])
    }

    @Test("midstream short paragraph merges backward with a single newline")
    func midShortMergesBackward() {
        let out = IndexHeaderHeuristic.mergeShortParagraphs(
            [Self.longBody, "Part Two", Self.secondBody],
            minChars: Self.minChars
        )
        #expect(out.count == 2)
        #expect(out[0] == Self.longBody + "\n" + "Part Two")
        #expect(out[1] == Self.secondBody)
    }

    @Test("all-short input keeps text via the no-prior-body fallback")
    func allShortFallback() {
        // First entry dropped; the rest accumulate without losing text.
        let out = IndexHeaderHeuristic.mergeShortParagraphs(
            ["Chapter 1", "Chapter 2", "Chapter 3"],
            minChars: Self.minChars
        )
        #expect(out.allSatisfy { !$0.isEmpty })
        #expect(out.joined().contains("Chapter 2"))
        #expect(out.joined().contains("Chapter 3"))
    }

    @Test("long paragraphs pass through untouched")
    func longUntouched() {
        let input = [Self.longBody, Self.secondBody]
        #expect(IndexHeaderHeuristic.mergeShortParagraphs(input, minChars: Self.minChars) == input)
    }

    @Test("custom threshold is respected")
    func customThreshold() {
        let header = "Short header twenty."
        #expect(header.count == 20)
        // threshold 10: header (20) is kept because 20 >= 10.
        let out = IndexHeaderHeuristic.mergeShortParagraphs([header, Self.longBody], minChars: 10)
        #expect(out == [header, Self.longBody])
    }
}
