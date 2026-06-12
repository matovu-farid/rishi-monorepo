//
//  EPUBReaderTTSExtension.swift
//  rishi (Phase 8 plan 08-06, refactored Phase 18 plan 18-05)
//
//  Adds a `currentReadAloudPassageIndex: Int?` hook + an async
//  `sentencesForReadAloud()` source to `EPUBReaderViewModel`.
//
//  Phase 18 plan 18-05 removed the OSAllocatedUnfairLock + `@unchecked
//  Sendable` boxing — all callers run on MainActor (RootView
//  startEPUBReadAloud + the @MainActor ReaderTTSBridge passage callback),
//  so a `@MainActor`-isolated dictionary is enough. Same pattern as commit
//  4bffec8f8 (AppChatRefreshAdapter cleanup).
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

    /// Index of the sentence currently being read aloud, or `nil` when no
    /// session is active. The setter touches an existing tracked field
    /// (`theme`) to wake @Observable trackers.
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

    /// Extract sentences from the current Readium resource. Best-effort:
    /// reads the resource the current locator points to, strips HTML, and
    /// runs `SentenceSplitter` over it. Returns `[]` on failure.
    public func sentencesForReadAloud() async -> [String] {
        guard let publication = publication,
              let locator = latestLocator else { return [] }
        guard let resource = publication.get(locator.href) else { return [] }
        let result = await resource.read().asString(encoding: .utf8)
        guard case .success(let html) = result else { return [] }
        let plain = Self.stripHTML(html)
        return SentenceSplitter.split(plain)
    }

    /// Cheap regex-based tag strip — good enough for sentence-level TTS
    /// extraction. We don't need DOM-accurate parsing for read-aloud copy.
    private static func stripHTML(_ html: String) -> String {
        let pattern = "<[^>]+>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        let stripped = regex.stringByReplacingMatches(
            in: html,
            range: range,
            withTemplate: " "
        )
        let collapsedWS = stripped.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        // Decode the most common HTML entities so TTS reads "don't" not "don&#39;t".
        return collapsedWS
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
