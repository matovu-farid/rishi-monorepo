//
//  PdfParagraphGrouper.swift
//  RishiCore
//
//  PDFKit-free heuristic that groups layout lines into paragraph blocks.
//
//  `PDFPage.string` joins visual lines with single `\n` and has no blank-line
//  paragraph boundaries, so PDF read-aloud fed the chunker one page-sized
//  blob and highlighted the whole page as a single chunk. PDFKit exposes line
//  geometry via `selectionsByLine()`; this type consumes those lines (as
//  `TextItem`s, one per line in reading order) and recovers paragraph breaks
//  from vertical spacing: a gap notably larger than the page's typical
//  line-to-line pitch is treated as a paragraph boundary — the layout
//  equivalent of a blank line.
//
//  The output is plain-text paragraphs (lines joined by a single space),
//  intended to be fed to `ParagraphChunker.chunk(_:)` for the maxChars
//  subdivision + trimming guarantees TTS relies on.
//

import Foundation
import CoreGraphics

public nonisolated enum PdfParagraphGrouper {

    /// Default multiple of the page's median line pitch above which a gap is
    /// treated as a paragraph break. 1.5 splits on extra inter-paragraph
    /// leading while tolerating the small pitch jitter of normal body lines.
    public nonisolated static let defaultGapRatio: CGFloat = 1.5

    /// Group reading-order layout `lines` into paragraph strings.
    ///
    /// - Parameters:
    ///   - lines: one `TextItem` per rendered line, in reading order (top to
    ///     bottom). Empty / whitespace-only lines are ignored.
    ///   - gapRatio: a vertical gap is a paragraph break when it exceeds
    ///     `gapRatio * medianPitch`.
    /// - Returns: trimmed, non-empty paragraph strings (lines joined by a
    ///   single space). A page with no usable lines yields `[]`.
    public nonisolated static func paragraphs(
        from lines: [TextItem],
        gapRatio: CGFloat = defaultGapRatio
    ) -> [String] {
        let usable = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return [] }

        let centers = usable.map { $0.frame.midY }
        var pitches: [CGFloat] = []
        pitches.reserveCapacity(usable.count - 1)
        for i in 1..<usable.count {
            pitches.append(abs(centers[i - 1] - centers[i]))
        }
        let medianPitch = median(pitches)

        var blocks: [String] = []
        var current: [String] = [usable[0].text]
        for i in 1..<usable.count {
            let gap = abs(centers[i - 1] - centers[i])
            if medianPitch > 0 && gap > gapRatio * medianPitch {
                blocks.append(current.joined(separator: " "))
                current = [usable[i].text]
            } else {
                current.append(usable[i].text)
            }
        }
        blocks.append(current.joined(separator: " "))

        return blocks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    nonisolated private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}
