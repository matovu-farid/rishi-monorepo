//
//  ParagraphChunker.swift
//  RishiCore (originally rishi/Audio/ParagraphChunker.swift — Phase 24 plan 24-02)
//
//  Moved from rishi/Audio/ParagraphChunker.swift in Phase 25-01 — RishiSearch
//  (RAG indexing) now consumes the same chunker as TTS, so the type has been
//  lifted from the rishi app target into the RishiCore SwiftPM package and
//  made public. Behavior is byte-for-byte preserved.
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
    /// indexing-side positional header heuristic. Matches
    /// `MIN_PARAGRAPH_LENGTH = 50` at
    /// apps/rishi-electron/src/renderer/src/components/pdf/utils/getPageParagraphs.ts:15.
    public nonisolated static let minBodyChars = 50

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
    public nonisolated static func chunkForIndexing(
        _ text: String,
        shortThreshold: Int = minBodyChars,
        maxChars: Int = maxParagraphChars
    ) -> [String] {
        let packed = chunk(text, maxChars: maxChars)
        return mergeShortParagraphs(packed, minChars: shortThreshold)
    }

    /// Mirror of the electron `getPageParagraphs.ts:188-219` filter:
    ///   - first paragraph with trimmed length `< minChars` is DROPPED
    ///     (suspected header — `filter((p, i) => i !== 0 || p.text.trim().length > MIN`).
    ///   - subsequent paragraphs with trimmed length `< minChars` are
    ///     popped + merged into the preceding emitted paragraph with a
    ///     single newline (`reduce` fallback).
    ///   - if a short paragraph appears before any body has been emitted,
    ///     it is appended as-is so we do not silently lose text (electron's
    ///     `if (!lastParagraph) acc.push(paragraph)` fallback).
    nonisolated private static func mergeShortParagraphs(
        _ paragraphs: [String],
        minChars: Int
    ) -> [String] {
        guard !paragraphs.isEmpty else { return paragraphs }
        var out: [String] = []
        for (i, p) in paragraphs.enumerated() {
            let trimmedCount = p
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .count
            if i == 0 && trimmedCount < minChars {
                // Drop leading short paragraph (suspected header).
                continue
            }
            if trimmedCount < minChars {
                if let last = out.popLast() {
                    out.append(last + "\n" + p)
                } else {
                    // No prior body yet — keep so we don't lose text.
                    // Mirrors electron reducer fallback at
                    // getPageParagraphs.ts:206-208.
                    out.append(p)
                }
            } else {
                out.append(p)
            }
        }
        return out
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
            let cleaned = insertBlockBoundaries(removeNonSpokenElements(text))
            if cleaned.range(of: "<p", options: .caseInsensitive) != nil {
                rawParagraphs = splitByPTags(cleaned)
            } else {
                // Split on blank-line boundaries FIRST, then strip tags per
                // block. Stripping first would collapse the boundaries we just
                // inserted (and any source blank lines) into single spaces.
                rawParagraphs = splitByBlankLines(cleaned).map { stripTags($0) }
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

    // MARK: - Boundary heuristics

    /// Split on `<p ...>...</p>` boundaries. Tolerates attributes on the open tag,
    /// case-insensitive. Anything outside `<p>` regions is treated as one more
    /// blank-line-separated block (so mixed `<p>` + raw blank-line input both work).
    nonisolated private static func splitByPTags(_ text: String) -> [String] {
        let pattern = "<p[^>]*>([\\s\\S]*?)</p>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return splitByBlankLines(text)
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)

        var paragraphs: [String] = []
        var cursor = 0
        for match in matches {
            let outside = NSRange(location: cursor, length: match.range.location - cursor)
            if outside.length > 0 {
                let chunk = nsText.substring(with: outside)
                paragraphs.append(contentsOf: splitOutsideRegion(chunk))
            }
            let inside = nsText.substring(with: match.range(at: 1))
            paragraphs.append(stripTags(inside))
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tail = nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
            paragraphs.append(contentsOf: splitOutsideRegion(tail))
        }
        return paragraphs
    }

    /// Handle a region that sits OUTSIDE any `<p>...</p>` (document scaffold,
    /// headings, list items, raw blank-line blocks). Inline / block tags here
    /// (`<h1>`, `<body>`, `<div>`, doctype, closing tags) MUST be stripped so
    /// markup is never spoken — the prior implementation forwarded these
    /// straight to `splitByBlankLines`, which leaked the raw XHTML scaffold
    /// into the TTS chunks (reader-tts-xml-and-loading symptom 1). We strip
    /// tags first, THEN split the resulting plain text on blank lines.
    nonisolated private static func splitOutsideRegion(_ region: String) -> [String] {
        // Split on blank-line boundaries FIRST (so raw blank-line-separated
        // paragraphs survive as distinct chunks), THEN strip tags per block.
        // `stripTags` collapses internal whitespace, so doing it before the
        // blank-line split would merge separate paragraphs into one chunk.
        return splitByBlankLines(region)
            .map { stripTags($0) }
            .filter { !$0.isEmpty }
    }

    /// Block-level HTML elements whose edges should start a new chunk even
    /// when no blank line separates them. EPUB/XHTML expresses paragraph
    /// structure with tags (headings, list items, divs) rather than blank
    /// lines, so the `<p>`-only + blank-line splitters lump a heading, an
    /// intro paragraph and a `<ul>` list into one chunk. Normalising these
    /// boundaries into blank lines up front lets the existing splitters break
    /// on them. Runs of inserted newlines collapse in `scanByBlankLines`, so
    /// emitting `\n\n` on both sides of every boundary tag is safe.
    nonisolated private static func insertBlockBoundaries(_ html: String) -> String {
        let blockTags = "p|div|li|ul|ol|h[1-6]|blockquote|section|article|aside"
            + "|header|footer|figure|figcaption|table|thead|tbody|tr|pre|hr"
        let pattern = "</?(?:\(blockTags))\\b[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "\n\n$0\n\n")
    }

    /// Remove element bodies that are never spoken: `<head>...</head>`,
    /// `<style>...</style>`, `<script>...</script>`. Without this the CSS /
    /// JS / `<title>` / `<meta>` text inside those elements survives tag
    /// stripping (it is character data, not markup) and gets read aloud.
    nonisolated private static func removeNonSpokenElements(_ html: String) -> String {
        var result = html
        for tag in ["head", "style", "script"] {
            let pattern = "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
            }
        }
        return result
    }

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

    // MARK: - Tag strip (HTML-cleanup)

    /// Inside-`<p>` content may still contain inline tags (`<em>`, `<a>`, `<br>`).
    /// Strip them to bare text for TTS.
    nonisolated private static func stripTags(_ html: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return html }
        let range = NSRange(html.startIndex..., in: html)
        let stripped = regex.stringByReplacingMatches(in: html, range: range, withTemplate: " ")
        let collapsed = stripped.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Oversize subdivision

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
