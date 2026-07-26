@testable import rishi
//
//  SentenceSplitterTests.swift
//  RishiCoreTests (Phase 25 plan 25-01)
//
//  Swift Testing coverage for `SentenceSplitter.split(_:)`. The splitter
//  pre-dated Phase 24's ParagraphChunker but never had its own test file —
//  it was exercised indirectly through ReaderTTSBridge / Phase 24 chunker
//  oversize-paragraph fallback paths. Now that it is public RishiCore API
//  (Phase 25-01 lift), it earns dedicated coverage so accidental contract
//  drift surfaces locally rather than via downstream consumers.
//

import Testing
import Foundation


struct SentenceSplitterTests {

    @Test
    func empty_input_returns_empty() {
        #expect(SentenceSplitter.split("") == [])
    }

    @Test
    func two_sentence_input_splits_into_two() {
        let out = SentenceSplitter.split("Hello world. How are you?")
        #expect(out == ["Hello world.", "How are you?"])
    }

    @Test
    func single_sentence_returns_itself_trimmed() {
        let out = SentenceSplitter.split("   Just one sentence.   ")
        #expect(out == ["Just one sentence."])
    }

    @Test
    func blank_lines_between_sentences_tolerated() {
        let input = "First sentence.\n\n\nSecond sentence!\n\nThird?"
        let out = SentenceSplitter.split(input)
        #expect(out.count == 3)
        #expect(out[0] == "First sentence.")
        #expect(out[1] == "Second sentence!")
        #expect(out[2] == "Third?")
    }

    @Test
    func whitespace_only_input_returns_empty() {
        #expect(SentenceSplitter.split("   \n  \t  ") == [])
    }

    @Test
    func emoji_is_preserved_in_sentence_content() {
        let out = SentenceSplitter.split("I love this book. It has emoji like this.")
        #expect(out.count == 2)
        #expect(out[0].contains("book"))
        #expect(out[1].contains("emoji"))
    }
}
