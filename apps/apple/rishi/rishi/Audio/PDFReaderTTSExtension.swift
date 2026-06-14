//
//  PDFReaderTTSExtension.swift
//  rishi (Phase 8 plan 08-06, refactored Phase 18 plan 18-05, Phase 24 plan 24-03)
//
//  Adds a `currentReadAloudPassageIndex: Int?` hook + a
//  `paragraphsForReadAloud(...)` text source to `PDFReaderViewModel`.
//
//  Phase 24 plan 24-03: renamed the public hook to
//  `paragraphsForReadAloud(...)` returning `ParagraphChunker.chunk(text)`.
//  Passage tracker semantics shift sentence -> paragraph (D7); data type
//  unchanged.
//
//  SwiftUI extensions can't add stored properties, so the per-VM index lives
//  in a file-private `ObjectIdentifier`-keyed dictionary. Phase 18 plan 18-05
//  removed the OSAllocatedUnfairLock + `@unchecked Sendable` boxing — all
//  callers (RootView startPDFReadAloud + the @MainActor ReaderTTSBridge
//  passage callback) run on MainActor, so a `@MainActor`-isolated storage
//  reference is enough. Same pattern as commit 4bffec8f8
//  (AppChatRefreshAdapter cleanup).
//
//  RishiReader has no dependency on RishiAudio (Feature layer hygiene), so
//  the bridge wiring lives here in the rishi app layer.
//

import Foundation
import PDFKit
import RishiCore
import RishiReader

/// MainActor-isolated storage for the per-VM read-aloud index. Default-
/// isolation = MainActor (Swift 6 strict) makes the explicit annotation
/// redundant in most files; here we make it explicit because the type is
/// touched from extension property accessors that callers may otherwise
/// expect to be nonisolated.
@MainActor
private final class PDFReadAloudIndexStore {
    var storage: [ObjectIdentifier: Int] = [:]
}

@MainActor
private let pdfReadAloudIndexStore = PDFReadAloudIndexStore()

extension PDFReaderViewModel {

    /// Index of the paragraph currently being read aloud, or `nil` when no
    /// session is active. The setter touches an existing tracked field
    /// (`theme`) so @Observable's automatic-tracking system wakes any
    /// SwiftUI subtree that reads this value. Phase 24 (D7): one index step
    /// is now one paragraph rather than one sentence; data type unchanged.
    @MainActor
    public var currentReadAloudPassageIndex: Int? {
        get { pdfReadAloudIndexStore.storage[ObjectIdentifier(self)] }
        set {
            let key = ObjectIdentifier(self)
            if let newValue {
                pdfReadAloudIndexStore.storage[key] = newValue
            } else {
                pdfReadAloudIndexStore.storage.removeValue(forKey: key)
            }
            // Wake @Observable trackers by writing-through an existing
            // tracked field. Same pattern the 05-06 highlight cache uses.
            self.theme = self.theme
        }
    }

    /// Extract paragraphs from the currently-visible page. Best-effort —
    /// many scanned PDFs have no embedded text and `PDFPage.string` returns
    /// nil; the bridge handles `[]` by no-op'ing.
    ///
    /// Phase 19 plan 19-04 (F-P0-06): marked `nonisolated` so callers can
    /// invoke this from `Task.detached(priority: .userInitiated)` without
    /// hopping back to MainActor for the PDFKit text extraction. The body
    /// reads only the function parameters (PDFDocument is non-Sendable but
    /// arrives as a `sending`-shaped parameter via the detached task's
    /// single-consumer transfer region) — no `self` state is touched.
    ///
    /// Phase 24 plan 24-03: switched from sentence-level to paragraph-level
    /// chunking via `ParagraphChunker.chunk(_:)`. `SentenceSplitter` is
    /// still used internally by the chunker as the oversize subdivide
    /// fallback (any paragraph >4096 chars).
    public nonisolated func paragraphsForReadAloud(document: PDFDocument, currentPageIndex: Int) -> [String] {
        guard let page = document.page(at: currentPageIndex) else { return [] }
        // Prefer layout-aware paragraph boundaries (line geometry) so a page
        // splits into real paragraphs instead of one page-sized chunk.
        let blocks = PDFReadAloudParagraphs.extract(from: page)
        guard !blocks.isEmpty else {
            // Scanned / no-geometry pages: preserve prior blank-line chunking.
            return ParagraphChunker.chunk(page.string ?? "")
        }
        return blocks.flatMap { ParagraphChunker.chunk($0) }
    }
}
