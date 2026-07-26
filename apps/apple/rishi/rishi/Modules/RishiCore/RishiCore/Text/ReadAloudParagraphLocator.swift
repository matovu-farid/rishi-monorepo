//
//  ReadAloudParagraphLocator.swift
//  RishiCore
//
//  Pure (engine-free) mapping from a read-aloud paragraph string back to its
//  character range inside the source page text. The TTS bridge tracks the
//  spoken passage as a 0-based index into `ParagraphChunker.chunk(_:)` output;
//  to render an inline highlight we have to find where that paragraph lives in
//  the original document text again. `ParagraphChunker` trims and collapses
//  internal whitespace, so a naive `range(of:)` against the raw page string
//  misses any paragraph that spanned a line break. This locator matches on a
//  whitespace-normalised view and maps the result back to the ORIGINAL string
//  indices, so callers (PDFKit `PDFSelection`, etc.) get a range valid against
//  the untouched page text.
//

import Foundation

public nonisolated enum ReadAloudParagraphLocator {

    /// Returns the range in `pageString` whose whitespace-normalised text
    /// equals the whitespace-normalised `paragraph`, or `nil` when the
    /// paragraph does not occur on the page. Matching is whitespace-tolerant
    /// because `ParagraphChunker` collapses internal whitespace while the
    /// source page text keeps its original line breaks and spacing.
    public static func range(
        of paragraph: String,
        in pageString: String
    ) -> Range<String.Index>? {
        let needle = normalize(paragraph)
        guard !needle.isEmpty, !pageString.isEmpty else { return nil }

        // Walk the page once, tracking the normalised form alongside a map
        // from each normalised character back to its origin index. A direct
        // substring search on the normalised string then translates straight
        // back to original `String.Index` bounds.
        var normalized = ""
        var originForNormalized: [String.Index] = []
        var lastWasSpace = true
        var idx = pageString.startIndex
        while idx < pageString.endIndex {
            let ch = pageString[idx]
            if ch.isWhitespace {
                if !lastWasSpace {
                    normalized.append(" ")
                    originForNormalized.append(idx)
                    lastWasSpace = true
                }
            } else {
                normalized.append(ch)
                originForNormalized.append(idx)
                lastWasSpace = false
            }
            idx = pageString.index(after: idx)
        }
        // Trailing collapsed space never anchors a match start/end.
        let trimmedNeedle = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmedNeedle.isEmpty,
              let foundRange = normalized.range(of: trimmedNeedle)
        else { return nil }

        let startOffset = normalized.distance(
            from: normalized.startIndex, to: foundRange.lowerBound
        )
        let endOffset = normalized.distance(
            from: normalized.startIndex, to: foundRange.upperBound
        )
        guard startOffset < originForNormalized.count else { return nil }
        let originStart = originForNormalized[startOffset]
        // The normalised upper bound is exclusive; map it to the origin index
        // just past the last matched non-space character.
        let originEnd: String.Index
        if endOffset == 0 {
            originEnd = originStart
        } else if endOffset - 1 < originForNormalized.count {
            originEnd = pageString.index(after: originForNormalized[endOffset - 1])
        } else {
            originEnd = pageString.endIndex
        }
        return originStart..<originEnd
    }

    private static func normalize(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
    }
}
