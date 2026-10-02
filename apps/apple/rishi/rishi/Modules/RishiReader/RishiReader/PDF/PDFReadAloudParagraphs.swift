//
//  PDFReadAloudParagraphs.swift
//  RishiReader
//
//  Layout-aware paragraph extraction for PDF read-aloud (TTS).
//
//  `PDFPage.string` joins visual lines with single `\n` and carries no
//  blank-line paragraph boundaries, so feeding it to `ParagraphChunker`
//  produced one page-sized chunk (and one page-spanning highlight). This
//  recovers paragraph structure from line geometry: PDFKit's
//  `selectionsByLine()` gives one selection per rendered line, which
//  `PdfParagraphGrouper` groups into paragraphs by vertical spacing.
//
//  `nonisolated` to match the read-aloud call site
//  (`PDFReaderViewModel.paragraphsForReadAloud`, F-P0-06), which runs the
//  PDFKit text read on a detached task and only touches the passed-in page —
//  the same off-main access pattern the prior `page.string` call used.
//

import Foundation
import CoreGraphics
import PDFKit

public enum PDFReadAloudParagraphs {
    public enum ParagraphRangeResult: Sendable, Equatable {
        /// Verified half-open UTF-16 ranges into the exact page string.
        case available([Range<Int>])
        case unavailable
    }

    /// Full read-aloud paragraph production for a single page. Prefers
    /// layout-aware boundaries (line geometry) via ``extract(from:)`` so a
    /// page splits into real paragraphs; for pages with no selectable text
    /// (scanned / image-only) it falls back to blank-line chunking of the raw
    /// page string. Both paths route through `ParagraphChunker.chunk(_:)` so
    /// downstream paragraph semantics (and the >4096-char subdivide) match.
    /// Returns `[]` when the page yields no text at all.
    ///
    /// This is the single source of per-page paragraph extraction shared by
    /// the initial read-aloud start (`PDFReaderViewModel.paragraphsForReadAloud`)
    /// and the page-boundary continuation
    /// (``PDFReaderViewModel/paragraphsForFollowingPage()``).
    public nonisolated static func paragraphs(from page: PDFPage) -> [String] {
        let blocks = extract(from: page)
        guard !blocks.isEmpty else {
            return ParagraphChunker.chunk(page.string ?? "")
        }
        return blocks.flatMap { ParagraphChunker.chunk($0) }
    }

    /// Extract layout-aware paragraph strings from a single page. Returns
    /// `[]` for pages with no selectable text (e.g. scanned image-only PDFs);
    /// callers should fall back to `PDFPage.string` chunking in that case.
    public nonisolated static func extract(from page: PDFPage) -> [String] {
        let charCount = page.numberOfCharacters
        guard charCount > 0,
              let pageSelection = page.selection(for: NSRange(location: 0, length: charCount))
        else { return [] }

        var lines: [TextItem] = []
        for line in pageSelection.selectionsByLine() {
            guard let raw = line.string, !raw.isEmpty else { continue }
            let frame = line.bounds(for: page)
            lines.append(TextItem(text: raw, frame: frame, fontSize: frame.height))
        }
        return PdfParagraphGrouper.paragraphs(from: lines)
    }

    /// Maps layout paragraphs to exact offsets in `pageText`. PDFKit ranges
    /// are authoritative; substring searching is intentionally never used,
    /// because repeated lines make that ambiguous.
    public nonisolated static func paragraphRanges(
        from page: PDFPage,
        pageText: String
    ) -> ParagraphRangeResult {
        guard let authoritativeText = page.string, authoritativeText == pageText else {
            return explicitBlankLineRanges(in: pageText)
        }
        let charCount = page.numberOfCharacters
        guard charCount > 0,
              let pageSelection = page.selection(for: NSRange(location: 0, length: charCount))
        else { return explicitBlankLineRanges(in: pageText) }

        var lineTexts: [String] = []
        var lineItems: [TextItem] = []
        var nativeRanges: [Range<Int>] = []
        for selection in pageSelection.selectionsByLine() {
            guard let text = selection.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            let count = selection.numberOfTextRanges(on: page)
            guard count > 0 else { return explicitBlankLineRanges(in: pageText) }
            var ranges: [Range<Int>] = []
            var selectedText = ""
            var previousRangeEnd = 0
            for index in 0..<count {
                let nsRange = selection.range(at: index, on: page)
                guard let range = checkedRange(nsRange, length: (pageText as NSString).length) else {
                    return explicitBlankLineRanges(in: pageText)
                }
                guard range.lowerBound >= previousRangeEnd else {
                    return explicitBlankLineRanges(in: pageText)
                }
                ranges.append(range)
                selectedText += (pageText as NSString).substring(with: nsRange)
                previousRangeEnd = range.upperBound
            }
            guard !ranges.isEmpty,
                  normalizedWhitespace(selectedText) == normalizedWhitespace(text),
                  let first = ranges.first,
                  let last = ranges.last
            else { return explicitBlankLineRanges(in: pageText) }

            lineTexts.append(text)
            let bounds = selection.bounds(for: page)
            lineItems.append(TextItem(text: text, frame: bounds, fontSize: bounds.height))
            nativeRanges.append(first.lowerBound..<last.upperBound)
        }
        guard !lineTexts.isEmpty else { return explicitBlankLineRanges(in: pageText) }
        let groups = PdfParagraphGrouper.lineGroups(from: lineItems)
        let result = paragraphRanges(
            pageText: pageText,
            lineGroups: groups,
            nativeLineRanges: nativeRanges,
            lineTexts: lineTexts
        )
        if case .unavailable = result { return explicitBlankLineRanges(in: pageText) }
        return result
    }

    /// Pure validation seam for native PDFKit ranges. Each line's text is
    /// checked against its supplied native range before paragraph endpoints
    /// are built from the existing line groups.
    nonisolated static func paragraphRanges(
        pageText: String,
        lineGroups: [Range<Int>],
        nativeLineRanges: [Range<Int>],
        lineTexts: [String]
    ) -> ParagraphRangeResult {
        let text = pageText as NSString
        guard !lineGroups.isEmpty,
              nativeLineRanges.count == lineTexts.count,
              nativeLineRanges.allSatisfy({
                  $0.lowerBound >= 0 && $0.upperBound <= text.length && !$0.isEmpty
              })
        else { return explicitBlankLineRanges(in: pageText) }

        var previousEnd = 0
        for index in nativeLineRanges.indices {
            let range = nativeLineRanges[index]
            guard range.lowerBound >= previousEnd,
                  normalizedWhitespace(text.substring(with: NSRange(location: range.lowerBound, length: range.count)))
                    == normalizedWhitespace(lineTexts[index])
            else { return explicitBlankLineRanges(in: pageText) }
            previousEnd = range.upperBound
        }

        var paragraphRanges: [Range<Int>] = []
        var expectedLineStart = 0
        for group in lineGroups {
            guard !group.isEmpty,
                  group.lowerBound == expectedLineStart,
                  group.upperBound <= nativeLineRanges.count
            else { return explicitBlankLineRanges(in: pageText) }
            let first = nativeLineRanges[group.lowerBound]
            let last = nativeLineRanges[group.upperBound - 1]
            guard first.lowerBound < last.upperBound else { return explicitBlankLineRanges(in: pageText) }
            paragraphRanges.append(first.lowerBound..<last.upperBound)
            expectedLineStart = group.upperBound
        }
        guard expectedLineStart == nativeLineRanges.count else { return explicitBlankLineRanges(in: pageText) }
        guard zip(paragraphRanges, paragraphRanges.dropFirst()).allSatisfy({ pair in
            pair.0.upperBound <= pair.1.lowerBound
        }) else {
            return explicitBlankLineRanges(in: pageText)
        }
        return .available(paragraphRanges)
    }

    nonisolated private static func checkedRange(_ range: NSRange, length: Int) -> Range<Int>? {
        guard range.location != NSNotFound,
              range.location >= 0,
              range.length > 0,
              range.location <= length,
              range.length <= length - range.location
        else { return nil }
        return range.location..<(range.location + range.length)
    }

    nonisolated private static func normalizedWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated private static func explicitBlankLineRanges(in value: String) -> ParagraphRangeResult {
        let text = value as NSString
        guard let expression = try? NSRegularExpression(pattern: #"(?:\r\n|\r|\n)[\t ]*(?:\r\n|\r|\n)+"#) else {
            return .unavailable
        }
        let boundaries = expression.matches(in: value, range: NSRange(location: 0, length: text.length))
        guard !boundaries.isEmpty else { return .unavailable }

        var ranges: [Range<Int>] = []
        var start = 0
        for boundary in boundaries {
            if let trimmed = trimmedRange(start..<boundary.range.location, in: text) {
                ranges.append(trimmed)
            }
            start = NSMaxRange(boundary.range)
        }
        if let trimmed = trimmedRange(start..<text.length, in: text) { ranges.append(trimmed) }
        return ranges.isEmpty ? .unavailable : .available(ranges)
    }

    nonisolated private static func trimmedRange(_ range: Range<Int>, in text: NSString) -> Range<Int>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        let whitespace = CharacterSet.whitespacesAndNewlines
        while lower < upper, let scalar = UnicodeScalar(text.character(at: lower)), whitespace.contains(scalar) {
            lower += 1
        }
        while upper > lower, let scalar = UnicodeScalar(text.character(at: upper - 1)), whitespace.contains(scalar) {
            upper -= 1
        }
        return lower < upper ? lower..<upper : nil
    }
}
