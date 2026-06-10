//
//  PDFReaderTTSExtension.swift
//  rishi (Phase 8 plan 08-06)
//
//  Adds a `currentReadAloudPassageIndex: Int?` hook + a
//  `sentencesForReadAloud(...)` text source to `PDFReaderViewModel` via the
//  external-lock box pattern (PDFReaderViewModel highlight cache, 05-06).
//
//  RishiReader has no dependency on RishiAudio (Feature layer hygiene), so
//  the bridge wiring lives here in the rishi app layer.
//

import Foundation
import PDFKit
import RishiReader
import os.lock

/// External-lock box mirroring the pattern used by the 05-06 highlight cache:
/// SwiftUI extensions can't add stored properties, so we keep the state in
/// an external `ObjectIdentifier`-keyed box. The box is private to this file.
private final class PDFReadAloudIndexBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: Int]())
    func get(_ id: ObjectIdentifier) -> Int? {
        lock.withLock { $0[id] }
    }
    func set(_ id: ObjectIdentifier, _ value: Int?) {
        lock.withLock { storage in
            if let value {
                storage[id] = value
            } else {
                storage.removeValue(forKey: id)
            }
        }
    }
}

private let pdfReadAloudIndexBox = PDFReadAloudIndexBox()

extension PDFReaderViewModel {

    /// Index of the sentence currently being read aloud, or `nil` when no
    /// session is active. The setter touches an existing tracked field
    /// (`theme`) so @Observable's automatic-tracking system wakes any
    /// SwiftUI subtree that reads this value.
    public var currentReadAloudPassageIndex: Int? {
        get { pdfReadAloudIndexBox.get(ObjectIdentifier(self)) }
        set {
            pdfReadAloudIndexBox.set(ObjectIdentifier(self), newValue)
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
