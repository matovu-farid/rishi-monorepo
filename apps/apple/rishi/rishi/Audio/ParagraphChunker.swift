//
//  ParagraphChunker.swift
//  rishi (Phase 24 plan 24-02)
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

enum ParagraphChunker {

    static let maxParagraphChars = 4096

    nonisolated static func chunk(_ text: String, maxChars: Int = maxParagraphChars) -> [String] {
        guard !text.isEmpty else { return [] }

        let rawParagraphs: [String]
        if text.contains("<p") {
            rawParagraphs = splitByPTags(text)
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
    private static func splitByPTags(_ text: String) -> [String] {
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
                paragraphs.append(contentsOf: splitByBlankLines(chunk))
            }
            let inside = nsText.substring(with: match.range(at: 1))
            paragraphs.append(stripTags(inside))
            cursor = match.range.location + match.range.length
        }
        if cursor < nsText.length {
            let tail = nsText.substring(with: NSRange(location: cursor, length: nsText.length - cursor))
            paragraphs.append(contentsOf: splitByBlankLines(tail))
        }
        return paragraphs
    }

    /// Split on blank-line boundaries (`\n\s*\n`).
    private static func splitByBlankLines(_ text: String) -> [String] {
        scanByBlankLines(text)
    }

    private static func scanByBlankLines(_ text: String) -> [String] {
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
    private static func stripTags(_ html: String) -> String {
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
    private static func subdivide(_ paragraph: String, maxChars: Int) -> [String] {
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
    private static func hardWordSplit(_ sentence: String, maxChars: Int) -> [String] {
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
