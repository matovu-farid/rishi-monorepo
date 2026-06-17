//
//  ProgressionIndexLocator.swift
//  RishiCore
//
//  Extracted from ParagraphChunker (plan 34-12 SRP split). One job: map a
//  within-resource reading progression to a paragraph index. Pure math, no
//  string/HTML work. ParagraphChunker.startIndex(forProgression:count:)
//  forwards here so existing callers (RishiReader read-aloud) are unchanged.
//

import Foundation

/// Maps a within-resource reading progression (0.0...1.0) to the index of the
/// first paragraph at or after that point.
public nonisolated enum ProgressionIndexLocator {

    /// Map a within-resource reading progression (0.0...1.0, as reported by
    /// Readium's `Locator.locations.progression`) to the index of the first
    /// paragraph at or after that point, for a resource chunked into `count`
    /// paragraphs.
    ///
    /// Read-aloud "Play" on a forwarded page must begin at the paragraph the
    /// reader is looking at, not paragraph 0 of the resource (the page-1 bug).
    /// The locator gives a fractional position inside the resource, so the
    /// corresponding paragraph is `floor(progression * count)`, clamped into
    /// range. A `nil`/out-of-range progression falls back to the start (0) so
    /// behaviour degrades to "read the whole resource" rather than crashing.
    ///
    /// - Returns: an index in `0..<count` (or 0 when `count == 0`).
    public nonisolated static func startIndex(forProgression progression: Double?, count: Int) -> Int {
        guard count > 0 else { return 0 }
        guard let progression, progression.isFinite, progression > 0 else { return 0 }
        let clamped = min(max(progression, 0), 1)
        let index = Int((Double(count) * clamped).rounded(.down))
        return min(index, count - 1)
    }
}
