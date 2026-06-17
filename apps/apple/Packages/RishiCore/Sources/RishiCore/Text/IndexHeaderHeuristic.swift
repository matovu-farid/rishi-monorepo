//
//  IndexHeaderHeuristic.swift
//  RishiCore
//
//  Extracted from ParagraphChunker (plan 34-12 SRP split). One job: the
//  indexing-side positional short-paragraph filter ported from electron
//  `getPageParagraphs.ts:188-219`. It folds suspected running headers / chapter
//  titles into the body that follows. ParagraphChunker.chunkForIndexing(_:)
//  forwards here, so the cross-package consumer (RishiSearch.IndexBuilder) is
//  unchanged. Pure, platform-agnostic string work.
//

import Foundation

/// Positional short-paragraph header heuristic for the search-indexing pipeline.
public nonisolated enum IndexHeaderHeuristic {

    /// Short-paragraph threshold (trimmed character count) for the
    /// indexing-side positional header heuristic. Matches
    /// `MIN_PARAGRAPH_LENGTH = 50` at
    /// apps/rishi-electron/src/renderer/src/components/pdf/utils/getPageParagraphs.ts:15.
    public nonisolated static let minBodyChars = 50

    /// Mirror of the electron `getPageParagraphs.ts:188-219` filter:
    ///   - first paragraph with trimmed length `< minChars` is DROPPED
    ///     (suspected header — `filter((p, i) => i !== 0 || p.text.trim().length > MIN`).
    ///   - subsequent paragraphs with trimmed length `< minChars` are
    ///     popped + merged into the preceding emitted paragraph with a
    ///     single newline (`reduce` fallback).
    ///   - if a short paragraph appears before any body has been emitted,
    ///     it is appended as-is so we do not silently lose text (electron's
    ///     `if (!lastParagraph) acc.push(paragraph)` fallback).
    nonisolated static func mergeShortParagraphs(
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
}
