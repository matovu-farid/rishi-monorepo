//
//  ParagraphChunkerTests.swift
//  RishiCoreTests (Phase 25 plan 25-01 — lifted from rishiTests Phase 24 plan 24-02)
//
//  Swift Testing coverage for `ParagraphChunker.chunk(_:maxChars:)`.
//
//  Ported verbatim from apps/apple/rishi/rishiTests/Audio/ParagraphChunkerTests.swift
//  with the import swapped from `@testable import rishi` to `import RishiCore`
//  now that the chunker lives in the package. Behavior coverage is unchanged.
//
//  Covers (per Phase 24 D3 + plan must_haves):
//    - empty / whitespace-only inputs return []
//    - single short paragraph passes through trimmed
//    - blank-line boundary detection (`\n\s*\n`), including runs of newlines
//      and whitespace-only paragraphs midstream
//    - single newlines inside a paragraph are preserved
//    - `<p>...</p>` HTML paragraph detection, including inline-tag stripping
//    - mixed `<p>` + raw blank-line input
//    - oversize-paragraph fallback through SentenceSplitter.split(_:),
//      with greedy reassembly under `maxChars` and no mid-word splits
//    - custom `maxChars` argument is respected
//    - pathological single-long-sentence input falls through to word-boundary
//      hard split without mid-word slicing
//

import Testing
import Foundation
import RishiCore

struct ParagraphChunkerTests {

    @Test
    func empty_input_returns_empty() {
        #expect(ParagraphChunker.chunk("") == [])
    }

    @Test
    func whitespace_only_returns_empty() {
        #expect(ParagraphChunker.chunk("   \n  \n  \n   ") == [])
    }

    @Test
    func single_short_paragraph_returns_itself_trimmed() {
        #expect(ParagraphChunker.chunk("  Hello world.  ") == ["Hello world."])
    }

    @Test
    func blank_line_splits_two_paragraphs() {
        let input = "First paragraph.\n\nSecond paragraph."
        #expect(ParagraphChunker.chunk(input) == ["First paragraph.", "Second paragraph."])
    }

    @Test
    func blank_line_run_collapses_to_one_boundary() {
        let input = "A.\n\n\n\nB."
        #expect(ParagraphChunker.chunk(input) == ["A.", "B."])
    }

    @Test
    func whitespace_only_paragraph_midstream_is_dropped() {
        let input = "Before.\n\n   \n\nAfter."
        #expect(ParagraphChunker.chunk(input) == ["Before.", "After."])
    }

    @Test
    func single_newline_inside_paragraph_preserved() {
        let input = "Line one\nstill paragraph one.\n\nSecond paragraph."
        let out = ParagraphChunker.chunk(input)
        #expect(out.count == 2)
        #expect(out[0].contains("Line one"))
        #expect(out[0].contains("still paragraph one."))
        #expect(out[1] == "Second paragraph.")
    }

    @Test
    func html_p_tags_split_paragraphs() {
        let input = "<p>First.</p><p>Second.</p>"
        #expect(ParagraphChunker.chunk(input) == ["First.", "Second."])
    }

    @Test
    func html_p_tags_with_inline_tags_stripped() {
        let input = "<p>An <em>emphatic</em> paragraph.</p><p>Another <a href='#'>link</a> here.</p>"
        let out = ParagraphChunker.chunk(input)
        #expect(out.count == 2)
        #expect(out[0] == "An emphatic paragraph.")
        #expect(out[1] == "Another link here.")
    }

    @Test
    func mixed_p_and_blank_line_handled() {
        let input = "<p>HTML para.</p>\n\nRaw para one.\n\nRaw para two."
        let out = ParagraphChunker.chunk(input)
        #expect(out.count == 3)
        #expect(out[0] == "HTML para.")
        #expect(out[1] == "Raw para one.")
        #expect(out[2] == "Raw para two.")
    }

    @Test
    func oversize_paragraph_subdivides_via_sentence_splitter() {
        // Build a paragraph whose count > maxChars by repeating a sentence.
        let sentence = "This is one sentence of text used to push the length over the cap. "
        let target = ParagraphChunker.maxParagraphChars + 200
        var paragraph = ""
        while paragraph.count < target {
            paragraph += sentence
        }
        #expect(paragraph.count > ParagraphChunker.maxParagraphChars)

        let out = ParagraphChunker.chunk(paragraph)
        #expect(out.count >= 2, "Oversize paragraph must produce multiple chunks")
        for chunk in out {
            #expect(chunk.count <= ParagraphChunker.maxParagraphChars, "every output chunk must fit under maxChars")
        }
        // Reassembled text contains every sentence boundary verbatim - no mid-word splits.
        let joined = out.joined(separator: " ")
        #expect(joined.contains("This is one sentence of text used to push the length over the cap."))
    }

    @Test
    func custom_maxChars_respected() {
        let input = "Short one. Short two. Short three. Short four."
        let out = ParagraphChunker.chunk(input, maxChars: 20)
        for chunk in out {
            #expect(chunk.count <= 20)
        }
        // All four sentences appear across the output, joined back together.
        let joined = out.joined(separator: " ")
        #expect(joined.contains("Short one."))
        #expect(joined.contains("Short four."))
    }

    @Test
    func single_long_sentence_hard_word_splits_under_cap() {
        // A 5000-char "sentence" with no period - must fall through to word-boundary
        // hard split and produce chunks under maxChars=4096 without mid-word splitting.
        let word = "wordtoken "
        var sentence = ""
        while sentence.count < 5000 {
            sentence += word
        }
        // Strip trailing space so it looks like one big sentence (no period).
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        let out = ParagraphChunker.chunk(trimmed)
        for chunk in out {
            #expect(chunk.count <= ParagraphChunker.maxParagraphChars)
            // Every chunk's content is a concatenation of whole `wordtoken` words,
            // separated by single spaces - i.e., no mid-word split.
            for fragment in chunk.split(separator: " ") {
                #expect(fragment == "wordtoken", "mid-word split detected: '\(fragment)'")
            }
        }
    }
}
