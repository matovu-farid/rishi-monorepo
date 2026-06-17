//
//  PDFReadAloudCursor.swift
//  RishiReader
//
//  Read-aloud page-continuation engine for the PDF reader. Extracted from
//  `PDFReaderViewModel` (plan 34-07) so the TTS-follow concern — scanning
//  pages for the next/previous page with selectable text — is separated from
//  the view-model's reading-position persistence concern.
//
//  The cursor performs the page scan + `PDFReadAloudParagraphs.paragraphs`
//  extraction and returns a *navigation intent* (the resolved page index and
//  its paragraphs). It deliberately does NOT mutate any position state: the
//  caller (`PDFReaderViewModel`) applies the resolved page via `seek(toPage:)`,
//  keeping the live-page mutation explicit rather than a hidden side effect of
//  paragraph fetching.
//

import Foundation
@preconcurrency import PDFKit

/// The outcome of a read-aloud page scan: the page the narration should land
/// on and that page's complete paragraph list. `nil` when no further page with
/// selectable text exists in the scan direction (end / start of document).
public struct PDFReadAloudPageResult: Sendable, Equatable {
    /// Zero-based index of the resolved non-empty page.
    public let pageIndex: Int
    /// Layout-aware paragraphs for ``pageIndex``.
    public let paragraphs: [String]

    public init(pageIndex: Int, paragraphs: [String]) {
        self.pageIndex = pageIndex
        self.paragraphs = paragraphs
    }
}

/// Owns the page-continuation scan for PDF read-aloud. Holds the document and
/// derives the next/previous narratable page from a caller-supplied current
/// page index, returning a ``PDFReadAloudPageResult`` intent.
///
/// Isolation: matches ``PDFReaderViewModel``'s `@unchecked Sendable` contract.
/// Justified the same way — it holds the non-Sendable `PDFDocument?` and only
/// reads pages (PDFKit page text extraction is safe off-main, the same pattern
/// `PDFReaderViewModel.load()`'s detached parse relies on). It has no mutable
/// state, so concurrent reads are race-free.
public final class PDFReadAloudCursor: @unchecked Sendable {

    private let document: PDFDocument?

    public init(document: PDFDocument?) {
        self.document = document
    }

    /// Scans forward from `currentPage` for the next page with selectable text,
    /// skipping intervening pages that yield zero paragraphs (blank / image-only
    /// separators). Returns `nil` at the end of the document.
    public func following(currentPage: Int) -> PDFReadAloudPageResult? {
        guard let document else { return nil }
        let count = document.pageCount
        var next = currentPage + 1
        while next < count {
            if let page = document.page(at: next) {
                let paragraphs = PDFReadAloudParagraphs.paragraphs(from: page)
                if !paragraphs.isEmpty {
                    return PDFReadAloudPageResult(pageIndex: next, paragraphs: paragraphs)
                }
            }
            next += 1
        }
        return nil
    }

    /// Scans backward from `currentPage` for the previous page with selectable
    /// text, skipping intervening empty pages. Returns `nil` at the start of the
    /// document.
    public func preceding(currentPage: Int) -> PDFReadAloudPageResult? {
        guard let document else { return nil }
        var prev = currentPage - 1
        while prev >= 0 {
            if let page = document.page(at: prev) {
                let paragraphs = PDFReadAloudParagraphs.paragraphs(from: page)
                if !paragraphs.isEmpty {
                    return PDFReadAloudPageResult(pageIndex: prev, paragraphs: paragraphs)
                }
            }
            prev -= 1
        }
        return nil
    }

    /// Best-effort paragraphs for `page`, or `[]` when the document isn't
    /// loaded or the page has no selectable text (image-only scans).
    public func paragraphs(atPage page: Int) -> [String] {
        guard let pdfPage = document?.page(at: page) else { return [] }
        return PDFReadAloudParagraphs.paragraphs(from: pdfPage)
    }
}
