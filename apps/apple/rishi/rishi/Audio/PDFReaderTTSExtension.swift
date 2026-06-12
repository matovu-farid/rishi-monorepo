//
//  PDFReaderTTSExtension.swift
//  rishi (Phase 8 plan 08-06, refactored Phase 18 plan 18-05)
//
//  Adds a `currentReadAloudPassageIndex: Int?` hook + a
//  `sentencesForReadAloud(...)` text source to `PDFReaderViewModel`.
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

    /// Index of the sentence currently being read aloud, or `nil` when no
    /// session is active. The setter touches an existing tracked field
    /// (`theme`) so @Observable's automatic-tracking system wakes any
    /// SwiftUI subtree that reads this value.
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

    /// Extract sentences from the currently-visible page. Best-effort —
    /// many scanned PDFs have no embedded text and `PDFPage.string` returns
    /// nil; the bridge handles `[]` by no-op'ing.
    public func sentencesForReadAloud(document: PDFDocument, currentPageIndex: Int) -> [String] {
        guard let page = document.page(at: currentPageIndex) else { return [] }
        let text = page.string ?? ""
        return SentenceSplitter.split(text)
    }
}
