//
//  EPUBReaderTTSExtension.swift
//  rishi (Phase 8 plan 08-06, refactored Phase 18 plan 18-05, Phase 24 plan 24-03)
//
//  Adds a `currentReadAloudPassageIndex: Int?` hook + an async
//  `paragraphsForReadAloud()` source to `EPUBReaderViewModel`.
//
//  Phase 18 plan 18-05 removed the OSAllocatedUnfairLock + `@unchecked
//  Sendable` boxing — all callers run on MainActor (RootView
//  startEPUBReadAloud + the @MainActor ReaderTTSBridge passage callback),
//  so a `@MainActor`-isolated dictionary is enough. Same pattern as commit
//  4bffec8f8 (AppChatRefreshAdapter cleanup).
//
//  Phase 24 plan 24-03: renamed the public hook to
//  `paragraphsForReadAloud()`. Returns paragraph-shaped chunks via
//  `ParagraphChunker.chunk(_:)` — the chunker has a native `<p>`-aware path
//  (D3), so the raw HTML is passed straight in without the previous
//  strip-then-split detour. Passage tracker semantics shift sentence ->
//  paragraph (D7); the underlying data types are unchanged.
//

import Foundation
import RishiReader
import ReadiumShared

/// MainActor-isolated storage for the per-VM read-aloud index. Mirrors the
/// PDFReaderTTSExtension store.
@MainActor
private final class EPUBReadAloudIndexStore {
    var storage: [ObjectIdentifier: Int] = [:]
}

@MainActor
private let epubReadAloudIndexStore = EPUBReadAloudIndexStore()

extension EPUBReaderViewModel {

    /// Index of the paragraph currently being read aloud, or `nil` when no
    /// session is active. The setter touches an existing tracked field
    /// (`theme`) to wake @Observable trackers. Phase 24 (D7): one index step
    /// is now one paragraph rather than one sentence; data type unchanged.
    @MainActor
    public var currentReadAloudPassageIndex: Int? {
        get { epubReadAloudIndexStore.storage[ObjectIdentifier(self)] }
        set {
            let key = ObjectIdentifier(self)
            if let newValue {
                epubReadAloudIndexStore.storage[key] = newValue
            } else {
                epubReadAloudIndexStore.storage.removeValue(forKey: key)
            }
            // Same wake-hook strategy as PDF.
            self.theme = self.theme
        }
    }

    /// Extract paragraphs from the current Readium resource. Best-effort:
    /// reads the resource the current locator points to and runs
    /// `ParagraphChunker.chunk(_:)` over the raw HTML. The chunker's
    /// `<p>`-aware path (D3) handles tag stripping; we no longer pre-strip
    /// to plain text. Returns `[]` on failure.
    public func paragraphsForReadAloud() async -> [String] {
        guard let publication = publication,
              let locator = latestLocator else { return [] }
        guard let resource = publication.get(locator.href) else { return [] }
        let result = await resource.read().asString(encoding: .utf8)
        guard case .success(let html) = result else { return [] }
        return ParagraphChunker.chunk(html)
    }
}
