import Foundation
import PDFKit


/// Phase 27-06 toggle for the PDF footer-detection pass.
///
/// Default `.disabled` on the type keeps any test or call site that hasn't
/// been updated to thread the policy through on the Phase 26 byte-stable
/// path. Production wiring in `AppDependencies` reads the
/// `FooterDetectionStore` value at hook-construction time and constructs the
/// extractor with `.enabled` accordingly.
///
/// Note: runtime toggle changes do NOT retroactively reindex already-indexed
/// books — the policy is captured at extractor-construction time. New books
/// get the new policy; old indices reflect their build-time policy until a
/// reimport / rebuild triggers a fresh extraction.
public enum FooterDropPolicy: Sendable, Equatable {
    case enabled
    case disabled
}

/// Per-page PDFKit text extractor. `page` in the result is the 1-based PDF
/// page index (matches the visible page number the reader shows).
///
/// Strategy:
///   1. Open via `PDFDocument(url:)`. Unreadable -> return `[]`.
///   2. For each page 0..<pageCount, read `page.string ?? ""`.
///   3. Paragraph-chunk via `RishiCore.ParagraphChunker.chunk(_:)`.
///   4. Emit one `(page: pageIndex + 1, text: chunk)` row per non-empty chunk.
///
/// Phase 27-06: when `footerPolicy == .enabled`, the extractor additionally
/// builds a layout-aware view of the document via PDFKit
/// `selectionsByLine()`, runs `FooterMaskBuilder` over the per-page paragraph
/// + layout streams, and drops paragraphs flagged as recurring page chrome
/// (page numbers, running titles, footnote blocks) before emitting rows.
/// When `footerPolicy == .disabled`, the extractor is byte-for-byte identical
/// to the Phase 26 baseline (the layout-aware path is never built, so there
/// is no risk of perturbing the chunk stream).
public struct PdfTextExtractor: PerBookTextExtractor {

    public let footerPolicy: FooterDropPolicy

    public init(footerPolicy: FooterDropPolicy = .disabled) {
        self.footerPolicy = footerPolicy
    }

    public func extractParagraphs(
        from fileURL: URL
    ) async throws -> [(page: Int, text: String)] {
        guard let document = PDFDocument(url: fileURL) else { return [] }

        // Phase 26 baseline path: chunk per page and emit as-is. When the
        // toggle is .disabled we MUST take this exact path to preserve
        // byte-stable output for already-indexed books.
        if footerPolicy == .disabled {
            return Self.extractPhase26Baseline(document: document)
        }

        // Phase 27 toggle-enabled path: build paragraphs + layout, run the
        // FooterMaskBuilder, and drop flagged paragraphs.
        return Self.extractWithFooterDrop(document: document)
    }

    // MARK: - Phase 26 byte-stable baseline

    /// Byte-stable Phase 26 path. Kept private + static so the `.disabled`
    /// branch above can never accidentally inherit a Phase 27 code path.
    private static func extractPhase26Baseline(
        document: PDFDocument
    ) -> [(page: Int, text: String)] {
        var result: [(page: Int, text: String)] = []
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let raw = page.string ?? ""
            let chunks = ParagraphChunker.chunk(raw)
            for chunk in chunks where !chunk.isEmpty {
                result.append((page: pageIndex + 1, text: chunk))
            }
        }
        return result
    }

    // MARK: - Phase 27 footer-drop path

    /// Phase 27-06 footer-drop path. Builds the per-page paragraph stream
    /// AND the layout-aware item stream, runs `FooterMaskBuilder`, drops
    /// masked paragraphs, and emits the survivors.
    private static func extractWithFooterDrop(
        document: PDFDocument
    ) -> [(page: Int, text: String)] {
        // 1. Build the per-page chunk stream + the layout-aware view in one
        //    pass. The paragraph index inside `PageParagraphs` is the
        //    reading-order slot used as the mask key.
        var paragraphsByPage: [PageParagraphs] = []
        var layout: [PageText] = []
        var pageNumbers: [Int] = []   // parallel to paragraphsByPage indexes

        paragraphsByPage.reserveCapacity(document.pageCount)
        layout.reserveCapacity(document.pageCount)
        pageNumbers.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let pageNumber = pageIndex + 1
            let raw = page.string ?? ""
            let chunks = ParagraphChunker.chunk(raw)
            let paragraphs = chunks.enumerated().compactMap { (i, t) -> PageParagraph? in
                guard !t.isEmpty else { return nil }
                return PageParagraph(index: i, text: t)
            }
            paragraphsByPage.append(
                PageParagraphs(pageNumber: pageNumber, paragraphs: paragraphs)
            )
            pageNumbers.append(pageNumber)
            layout.append(extractLayout(from: page, pageIndex: pageIndex))
        }

        // 2. Build the mask. The FooterMaskBuilder skips layout strategies
        //    when pages.count < minPages, so short PDFs short-circuit
        //    cleanly to an empty mask.
        let mask = FooterMaskBuilder.build(
            inputs: FooterMaskBuilder.Inputs(
                layout: layout,
                paragraphsByPage: paragraphsByPage
            )
        )

        // 3. Emit survivors. Iterate the original paragraph list (not the
        //    mask) so unmasked paragraphs keep their stream-order index
        //    slot, mirroring electron's "preserve index slot" semantics.
        var result: [(page: Int, text: String)] = []
        for pageParagraphs in paragraphsByPage {
            let dropSet = mask[pageParagraphs.pageNumber] ?? []
            for paragraph in pageParagraphs.paragraphs {
                if dropSet.contains(paragraph.index) { continue }
                if paragraph.text.isEmpty { continue }
                result.append((page: pageParagraphs.pageNumber, text: paragraph.text))
            }
        }
        return result
    }

    /// Layout-aware per-page extraction via PDFKit `selectionsByLine()`.
    /// Mirrors `PDFLayoutExtractor` in RishiReader (Phase 27-01) but is
    /// inlined here to avoid a RishiLibrary -> RishiReader dependency.
    /// One TextItem per LINE; fontSize approximated by line bounding-box
    /// height (the same approximation Phase 27-01 documents).
    private static func extractLayout(from page: PDFPage, pageIndex: Int) -> PageText {
        let mediaBox = page.bounds(for: .mediaBox)
        let charCount = page.numberOfCharacters
        let lines: [PDFSelection]
        if charCount > 0,
           let pageSelection = page.selection(for: NSRange(location: 0, length: charCount)) {
            lines = pageSelection.selectionsByLine()
        } else {
            lines = []
        }
        var items: [TextItem] = []
        items.reserveCapacity(lines.count)
        for line in lines {
            guard let raw = line.string, !raw.isEmpty else { continue }
            let frame = line.bounds(for: page)
            items.append(TextItem(
                text: raw,
                frame: frame,
                fontSize: frame.height
            ))
        }
        return PageText(pageIndex: pageIndex, frame: mediaBox, items: items)
    }
}
