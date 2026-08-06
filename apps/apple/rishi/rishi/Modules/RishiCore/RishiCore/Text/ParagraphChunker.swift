//
//  ParagraphChunker.swift
//  RishiCore (originally rishi/Audio/ParagraphChunker.swift — Phase 24 plan 24-02)
//
//  Moved from rishi/Audio/ParagraphChunker.swift in Phase 25-01 — RishiSearch
//  (RAG indexing) now consumes the same chunker as TTS, so the type has been
//  lifted from the rishi app target into the RishiCore SwiftPM package and
//  made public. Behavior is byte-for-byte preserved.
//
//  Plan 34-12 SRP split: the four algorithms this namespace bundled have been
//  factored into focused units, keeping this type's public surface stable:
//    - HTML/XHTML cleanup -> `HTMLTextCleaner`
//    - indexing header heuristic -> `IndexHeaderHeuristic`
//    - progression -> paragraph index -> `ProgressionIndexLocator`
//    - paragraph chunking (this file) drives them and forwards the public
//      `chunkForIndexing`, `startIndex`, `minBodyChars` symbols so existing
//      callers (RishiSearch, RishiReader) compile unchanged.
//
//  Splits a page of text into paragraph-sized chunks for TTS. Replaces the
//  per-sentence chunking used in Phases 8..23: each paragraph becomes one
//  `TTSStreamRequest`, which collapses HTTP/cache fan-out and lets the
//  Phase-24 prewarmer warm whole paragraphs ahead of the play head.
//
//  Heuristic (D3):
//    1. If the text contains `<p` tags, treat each `<p>...</p>` as a paragraph.
//    2. Otherwise (and as the secondary pass for non-<p> regions), split on
//       blank-line boundaries (`\n\s*\n`).
//    3. Trim per-chunk whitespace; drop empty results.
//    4. Any chunk whose `.count` exceeds `maxChars` is subdivided via
//       `SentenceSplitter.split(_:)` and greedily reassembled so every
//       returned chunk has `.count <= maxChars` and no chunk splits a word.
//
//  SentenceSplitter survives ONLY as the subdivide-fallback path inside this
//  chunker. EPUB + PDF callers now route through ParagraphChunker.chunk(_:).
//

import Foundation

public nonisolated enum ParagraphChunker {

    public nonisolated static let maxParagraphChars = 4096

    /// Short-paragraph threshold (trimmed character count) for the
    /// indexing-side positional header heuristic. Forwards to
    /// `IndexHeaderHeuristic.minBodyChars` (kept here for source stability of
    /// existing `ParagraphChunker.minBodyChars` callers).
    public nonisolated static let minBodyChars = IndexHeaderHeuristic.minBodyChars

    /// Indexing-side variant of `chunk(_:maxChars:)` that, in addition to
    /// greedy paragraph packing under `maxChars`, applies the electron
    /// positional short-paragraph heuristic to fold suspected running
    /// headers / chapter titles into the body that follows:
    ///
    ///   1. Drop the FIRST paragraph if its trimmed length is `< shortThreshold`
    ///      (suspected running header).
    ///   2. For every other paragraph whose trimmed length is
    ///      `< shortThreshold`, merge it into the preceding emitted
    ///      paragraph with a single `\n` separator.
    ///   3. Then return the greedy-packed result under `maxChars`.
    ///
    /// Note: the merge step concatenates a short tail (`< shortThreshold`
    /// chars) onto the preceding chunk, so post-merge chunks may exceed
    /// `maxChars` by up to `shortThreshold - 1` chars. Callers that need
    /// byte-stable boundaries (TTS / Phase 22 sha256 cache / Phase 24
    /// paragraph audio cache) MUST keep using `chunk(_:maxChars:)`.
    ///
    /// Today this is consumed by `RishiSearch.IndexBuilder` on the oversize
    /// branch only — per-paragraph rows that already fit under the embed
    /// cap bypass this method. A future phase will move the heuristic
    /// upstream to the PDF/EPUB import pipeline where it can drop title
    /// rows wholesale.
    ///
    /// The header heuristic itself lives in `IndexHeaderHeuristic`; this
    /// method composes it with the chunker's greedy packing.
    public nonisolated static func chunkForIndexing(
        _ text: String,
        shortThreshold: Int = minBodyChars,
        maxChars: Int = maxParagraphChars
    ) -> [String] {
        let packed = chunk(text, maxChars: maxChars)
        return IndexHeaderHeuristic.mergeShortParagraphs(packed, minChars: shortThreshold)
    }

    /// Map a within-resource reading progression to the index of the first
    /// paragraph at or after that point. Forwards to `ProgressionIndexLocator`;
    /// kept here for source stability of existing
    /// `ParagraphChunker.startIndex(forProgression:count:)` callers.
    ///
    /// - Returns: an index in `0..<count` (or 0 when `count == 0`).
    public nonisolated static func startIndex(forProgression progression: Double?, count: Int) -> Int {
        ProgressionIndexLocator.startIndex(forProgression: progression, count: count)
    }

    public nonisolated static func chunk(_ text: String, maxChars: Int = maxParagraphChars) -> [String] {
        guard !text.isEmpty else { return [] }

        let rawParagraphs: [String]
        if text.contains("<") {
            // Any markup present (full XHTML doc from Readium, or a raw
            // `<p>` fragment) routes through the tag-aware path. First drop
            // non-spoken element bodies (`<head>`, `<style>`, `<script>`)
            // wholesale so their CSS / JS / metadata text never reaches TTS,
            // then split on `<p>` boundaries (with the outside-`<p>` regions
            // tag-stripped too). Anything left without `<p>` tags still gets
            // its inline tags stripped before blank-line splitting.
            let cleaned = HTMLTextCleaner.prepare(text)
            if cleaned.range(of: "<p", options: .caseInsensitive) != nil {
                rawParagraphs = HTMLTextCleaner.splitByPTags(cleaned, blankLineSplit: splitByBlankLines)
            } else {
                // Split on blank-line boundaries FIRST, then strip tags per
                // block. Stripping first would collapse the boundaries we just
                // inserted (and any source blank lines) into single spaces.
                rawParagraphs = splitByBlankLines(cleaned).map { HTMLTextCleaner.stripTags($0) }
            }
        } else {
            rawParagraphs = splitByBlankLines(text)
        }

        var output: [String] = []
        for paragraph in rawParagraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= maxChars {
                output.append(trimmed)
            } else {
                output.append(contentsOf: subdivide(trimmed, maxChars: maxChars))
            }
        }
        return output
    }

    /// Splits text into requests that fit the Worker's UTF-16 length limit.
    /// The normal paragraph chunker measures Swift `Character`s, while the
    /// Worker validates JavaScript `text.length` (UTF-16 code units). Keep
    /// this boundary in the shared text layer so playback and prefetch use
    /// exactly the same request sizing rule.
    public nonisolated static func chunkForTTS(
        _ text: String,
        maxChars: Int = 4000
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        return chunk(text, maxChars: maxChars).flatMap {
            splitUTF16($0, maxChars: maxChars)
        }
    }

    // MARK: - Blank-line splitting

    /// Split on blank-line boundaries (`\n\s*\n`).
    nonisolated private static func splitByBlankLines(_ text: String) -> [String] {
        scanByBlankLines(text)
    }

    nonisolated private static func scanByBlankLines(_ text: String) -> [String] {
        // Manual blank-line scanner: a "blank line" is a `\n` followed by zero-or-more
        // whitespace chars then another `\n`. Collapses runs of >=2 newlines into a
        // single boundary; single `\n` inside a paragraph is preserved.
        var paragraphs: [String] = []
        var current = ""
        var newlineRun = 0
        for ch in text {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun >= 2 {
                    if !current.isEmpty {
                        paragraphs.append(current)
                        current = ""
                    }
                    continue
                }
                current.append(ch)
            } else if ch.isWhitespace && newlineRun >= 1 {
                // Whitespace inside a potential blank-line boundary — keep collecting.
                current.append(ch)
            } else {
                newlineRun = 0
                current.append(ch)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current)
        }
        return paragraphs
    }

    // MARK: - Oversize subdivision

    private nonisolated static func splitUTF16(
        _ text: String,
        maxChars: Int
    ) -> [String] {
        guard text.utf16.count > maxChars else { return [text] }

        var output: [String] = []
        var start = text.startIndex
        var cursor = start
        var units = 0
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            let nextUnits = text[cursor..<next].utf16.count
            if units > 0, units + nextUnits > maxChars {
                output.append(String(text[start..<cursor]))
                start = cursor
                units = 0
            }
            units += nextUnits
            cursor = next
        }
        if start < text.endIndex {
            output.append(String(text[start..<text.endIndex]))
        }
        return output.isEmpty ? [text] : output
    }

    /// Subdivide a paragraph whose `.count > maxChars` into a list of chunks
    /// each `.count <= maxChars`. Uses SentenceSplitter to find natural sentence
    /// boundaries, then greedily packs sentences into chunks under the cap. If a
    /// single sentence is itself longer than maxChars (pathological), it is hard-
    /// split on word boundaries to stay under the cap.
    nonisolated private static func subdivide(_ paragraph: String, maxChars: Int) -> [String] {
        let sentences = SentenceSplitter.split(paragraph)
        guard !sentences.isEmpty else { return [paragraph] }

        var output: [String] = []
        var current = ""
        for sentence in sentences {
            if sentence.count > maxChars {
                // Pathological: split sentence on word boundaries.
                if !current.isEmpty {
                    output.append(current)
                    current = ""
                }
                output.append(contentsOf: hardWordSplit(sentence, maxChars: maxChars))
                continue
            }
            let joiner = current.isEmpty ? "" : " "
            if current.count + joiner.count + sentence.count <= maxChars {
                current += joiner + sentence
            } else {
                output.append(current)
                current = sentence
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    /// Last-resort word-boundary split for a sentence that itself exceeds maxChars.
    /// Never splits inside a word.
    nonisolated private static func hardWordSplit(_ sentence: String, maxChars: Int) -> [String] {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var chunks: [String] = []
        var current = ""
        for word in words {
            let joiner = current.isEmpty ? "" : " "
            if current.count + joiner.count + word.count <= maxChars {
                current += joiner + word
            } else {
                if !current.isEmpty { chunks.append(current) }
                if word.count > maxChars {
                    // Single token longer than the cap - emit as-is rather than
                    // mid-word split (per D3: "never mid-word split"). This is
                    // pathological input and accepted.
                    chunks.append(word)
                    current = ""
                } else {
                    current = word
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
