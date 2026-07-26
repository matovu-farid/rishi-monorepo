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

    /// Bug 1 "trailing space" hypothesis (readaloud-nextprev-page): a short
    /// chapter-title heading with surrounding whitespace must NOT reach TTS as a
    /// whitespace-only or trailing-space passage. `chunk(_:)` trims every chunk
    /// and drops empties, so a 27-char title like "Why You Need the Purple Cow"
    /// surfaces as a clean, non-empty, non-trailing-space passage — and a
    /// heading that is ONLY whitespace is dropped entirely.
    @Test
    func short_title_heading_is_trimmed_not_whitespace_passage() {
        let title = "Why You Need the Purple Cow"
        let html = "<h1>  \(title)  </h1><p>Body paragraph that follows the heading.</p>"
        let out = ParagraphChunker.chunk(html)
        #expect(out.contains(title), "heading must surface trimmed, exactly: \(out)")
        // No chunk may be whitespace-only or carry leading/trailing whitespace.
        for chunk in out {
            #expect(!chunk.isEmpty)
            #expect(chunk == chunk.trimmingCharacters(in: .whitespacesAndNewlines),
                    "chunk has leading/trailing whitespace: \"\(chunk)\"")
        }
    }

    @Test
    func whitespace_only_heading_is_dropped() {
        let html = "<h1>   </h1><p>Real body text here.</p>"
        #expect(ParagraphChunker.chunk(html) == ["Real body text here."])
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
    func full_xhtml_document_strips_all_markup() {
        // Regression: an EPUB resource from Readium is a full XHTML doc.
        // Content OUTSIDE <p> regions (head/title/style/CSS, headings,
        // doctype, closing tags) must NOT leak into the spoken chunks.
        let input = """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>Chapter 1</title>
          <link rel="stylesheet" type="text/css" href="style.css"/>
          <style>body { margin: 0; } p { text-indent: 1em; }</style>
        </head>
        <body>
          <h1>Chapter One</h1>
          <p>It was a bright cold day in April.</p>
          <p>The clocks were striking thirteen.</p>
        </body>
        </html>
        """
        let out = ParagraphChunker.chunk(input)
        // No chunk may contain markup or CSS leakage.
        for chunk in out {
            #expect(!chunk.contains("<"), "markup leaked into spoken chunk: \(chunk)")
            #expect(!chunk.contains(">"), "markup leaked into spoken chunk: \(chunk)")
            #expect(!chunk.contains("margin"), "CSS leaked into spoken chunk: \(chunk)")
            #expect(!chunk.contains("DOCTYPE"), "doctype leaked into spoken chunk: \(chunk)")
            #expect(!chunk.contains("stylesheet"), "head leaked into spoken chunk: \(chunk)")
        }
        // The real prose survives.
        let joined = out.joined(separator: " ")
        #expect(joined.contains("It was a bright cold day in April."))
        #expect(joined.contains("The clocks were striking thirteen."))
    }

    @Test
    func heading_outside_p_is_kept_as_clean_text() {
        // An <h1> heading sits outside any <p>; its text should be spoken
        // (stripped of the tag), not dropped and not leaked as markup.
        let input = "<body><h1>Chapter One</h1><p>Body text here.</p></body>"
        let out = ParagraphChunker.chunk(input)
        let joined = out.joined(separator: " ")
        #expect(joined.contains("Chapter One"))
        #expect(joined.contains("Body text here."))
        for chunk in out {
            #expect(!chunk.contains("<"))
            #expect(!chunk.contains(">"))
        }
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
    func chunk_semantics_unchanged_assertion() {
        // Pin: the existing `chunk(_:maxChars:)` keeps short paragraphs in
        // place. Plan 26-02 must NOT alter this behaviour — the indexing-side
        // header drop is opt-in via `chunkForIndexing`.
        #expect(
            ParagraphChunker.chunk(
                "Chapter 1\n\nBody paragraph well past fifty characters of body text content."
            )
            ==
            ["Chapter 1", "Body paragraph well past fifty characters of body text content."]
        )
    }

    @Test
    func list_items_split_into_separate_chunks() {
        // A <ul>/<li> list expresses structure with tags, not blank lines.
        // Each item should become its own chunk, not collapse into one.
        let input = "<p>Some of them include:</p><ul><li>Product</li><li>Pricing</li></ul>"
        #expect(
            ParagraphChunker.chunk(input)
            == ["Some of them include:", "Product", "Pricing"]
        )
    }

    @Test
    func list_after_paragraph_not_merged_with_neighbours() {
        // Screenshot regression: intro paragraph + bullet list + trailing
        // paragraph were highlighted as ONE chunk. They must be distinct.
        let input = "<p>Some of them include:</p>"
            + "<ul><li>Product</li><li>Pricing</li></ul>"
            + "<p>This is the marketing checklist.</p>"
        #expect(
            ParagraphChunker.chunk(input)
            == ["Some of them include:", "Product", "Pricing", "This is the marketing checklist."]
        )
    }

    @Test
    func heading_and_list_without_p_split_into_blocks() {
        // Heading + div body + list, none wrapped in <p>. Block-level tags
        // must still act as chunk boundaries.
        let input = "<h2>Not Enough Ps</h2>"
            + "<div>Marketers have long talked about the five Ps.</div>"
            + "<ul><li>Product</li><li>Pricing</li></ul>"
        #expect(
            ParagraphChunker.chunk(input)
            == ["Not Enough Ps", "Marketers have long talked about the five Ps.", "Product", "Pricing"]
        )
    }

    @Test
    func div_separated_blocks_split_without_p_tags() {
        // Markup present but NO <p> anywhere (line-127 branch). Block
        // boundaries must survive instead of collapsing to one chunk.
        let input = "<div>First block.</div><div>Second block.</div>"
        #expect(
            ParagraphChunker.chunk(input)
            == ["First block.", "Second block."]
        )
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

// MARK: - Plan 26-02: chunkForIndexing

/// Tests for the indexing-side positional short-paragraph heuristic ported
/// from electron `getPageParagraphs.ts:188-219`.
///
/// Contract:
///   1. Drop the first paragraph if its trimmed length is `< minBodyChars`
///      (suspected running header / chapter title).
///   2. For every other paragraph whose trimmed length is `< minBodyChars`,
///      merge it into the preceding emitted paragraph with a single `\n`
///      separator.
///   3. Long paragraphs pass through unchanged.
///
/// Threshold is exclusive (matches plan `< minChars`). Custom `shortThreshold`
/// must be respected.
/// Pure start-index math for the read-aloud "Play starts on the current page"
/// fix (readaloud-nextprev-page bug 2). Maps a within-resource progression to
/// the paragraph the reader is looking at.
@Suite("ParagraphChunker.startIndex(forProgression:count:)")
struct ParagraphChunkerStartIndexTests {

    @Test("progression 0 / nil / negative all start at paragraph 0")
    func startStaysAtZeroForResourceStart() {
        #expect(ParagraphChunker.startIndex(forProgression: 0, count: 10) == 0)
        #expect(ParagraphChunker.startIndex(forProgression: nil, count: 10) == 0)
        #expect(ParagraphChunker.startIndex(forProgression: -0.5, count: 10) == 0)
    }

    @Test("mid-resource progression maps to floor(progression * count)")
    func midProgressionFloors() {
        // 0.25 * 8 = 2.0 -> 2; 0.5 * 8 = 4; 0.99 * 8 = 7.92 -> 7.
        #expect(ParagraphChunker.startIndex(forProgression: 0.25, count: 8) == 2)
        #expect(ParagraphChunker.startIndex(forProgression: 0.5, count: 8) == 4)
        #expect(ParagraphChunker.startIndex(forProgression: 0.99, count: 8) == 7)
    }

    @Test("progression >= 1 clamps to the last paragraph, never out of range")
    func fullProgressionClampsToLast() {
        #expect(ParagraphChunker.startIndex(forProgression: 1.0, count: 8) == 7)
        #expect(ParagraphChunker.startIndex(forProgression: 5.0, count: 8) == 7)
    }

    @Test("empty resource yields 0 (no crash)")
    func emptyResourceIsZero() {
        #expect(ParagraphChunker.startIndex(forProgression: 0.5, count: 0) == 0)
    }

    @Test("non-finite progression (nan/inf) degrades to 0 rather than risking a bad index")
    func nonFiniteIsZero() {
        #expect(ParagraphChunker.startIndex(forProgression: .nan, count: 8) == 0)
        #expect(ParagraphChunker.startIndex(forProgression: .infinity, count: 8) == 0)
    }
}

@Suite("ParagraphChunker.chunkForIndexing")
struct ParagraphChunkerForIndexingTests {

    /// Body string comfortably above the 50-char minimum.
    private static let longBody =
        "First body paragraph that is comfortably above the 50-character minimum threshold for body text."
    private static let secondBody =
        "Second body paragraph that is also clearly above the fifty character minimum body threshold."

    @Test
    func leading_short_paragraph_dropped() {
        let input = "Chapter 1\n\n" + Self.longBody
        let out = ParagraphChunker.chunkForIndexing(input)
        #expect(out == [Self.longBody])
    }

    @Test
    func leading_long_paragraph_kept() {
        let leading =
            "A long opening paragraph well past fifty characters that is definitely body text."
        let input = leading + "\n\n" + Self.secondBody
        let out = ParagraphChunker.chunkForIndexing(input)
        #expect(out == [leading, Self.secondBody])
    }

    @Test
    func midstream_short_paragraph_merged_backward() {
        let body1 =
            "Body one is long enough to be a body paragraph by length, comfortably."
        let body2 = "Body two is also long enough to count as body text content here."
        let input = body1 + "\n\nPart Two\n\n" + body2
        let out = ParagraphChunker.chunkForIndexing(input)
        #expect(out.count == 2)
        #expect(out[0].contains("Part Two"))
        #expect(out[0].hasPrefix(body1))
        #expect(out[1] == body2)
    }

    @Test
    func short_sentence_like_paragraph_merged() {
        let body =
            "A body paragraph comfortably past the fifty-character minimum threshold."
        let input = body + "\n\nDone."
        let out = ParagraphChunker.chunkForIndexing(input)
        #expect(out.count == 1)
        #expect(out[0].contains("Done."))
        #expect(out[0].hasPrefix(body))
    }

    @Test
    func all_short_paragraphs_handled_gracefully() {
        // Fake table of contents. First entry is dropped. Remaining short
        // paragraphs accumulate via the popLast/append fallback in
        // `mergeShortParagraphs`.
        let input = "Chapter 1\n\nChapter 2\n\nChapter 3"
        let out = ParagraphChunker.chunkForIndexing(input)
        #expect(out.allSatisfy { !$0.isEmpty })
    }

    @Test
    func long_paragraphs_untouched() {
        let p1 =
            "Paragraph one that is comfortably above the fifty character minimum threshold."
        let p2 =
            "Paragraph two that is also comfortably above the fifty character minimum threshold."
        let p3 =
            "Paragraph three is also long enough to clearly count as actual body text content."
        let input = p1 + "\n\n" + p2 + "\n\n" + p3
        let out = ParagraphChunker.chunkForIndexing(input)
        #expect(out == [p1, p2, p3])
    }

    @Test
    func custom_shortThreshold_respected() {
        // With threshold = 10, a 20-char header is kept because 20 >= 10.
        let header = "Short header twenty."
        #expect(header.count == 20)
        let input = header + "\n\n" + Self.longBody
        let out = ParagraphChunker.chunkForIndexing(input, shortThreshold: 10)
        #expect(out == [header, Self.longBody])
    }

    @Test
    func empty_input_returns_empty() {
        #expect(ParagraphChunker.chunkForIndexing("") == [])
    }

    @Test
    func maxChars_still_respected() {
        // Multi-paragraph input: tiny header (<50 chars, dropped) + giant
        // body (> maxChars, must be subdivided via greedy packing). After
        // the merge pass, every chunk should respect maxChars within the
        // documented tolerance of `+ shortThreshold` (the merge step can
        // grow a chunk by concatenating a short tail).
        let sentence = "This is a coherent sentence with twenty-plus characters. "
        var giantBody = ""
        while giantBody.count < 800 {
            giantBody += sentence
        }
        let input = "Chapter 1\n\n" + giantBody + "\n\nDone."
        let maxChars = 200
        let shortThreshold = ParagraphChunker.minBodyChars
        let out = ParagraphChunker.chunkForIndexing(
            input,
            shortThreshold: shortThreshold,
            maxChars: maxChars
        )
        // Header dropped, body subdivided into multiple sub-chunks, trailing
        // "Done." merged into last sub-chunk. Every chunk respects the
        // documented relaxation: `<= maxChars + shortThreshold`.
        #expect(!out.isEmpty)
        for chunk in out {
            #expect(
                chunk.count <= maxChars + shortThreshold,
                "chunk exceeded maxChars + shortThreshold relaxation: \(chunk.count)"
            )
        }
    }
}
