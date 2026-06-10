//
//  EPUBReaderTTSExtension.swift
//  rishi (Phase 8 plan 08-06)
//
//  Adds a `currentReadAloudPassageIndex: Int?` hook + an async
//  `sentencesForReadAloud()` source to `EPUBReaderViewModel` via the same
//  external-lock box pattern as the PDF extension.
//

import Foundation
import RishiReader
import ReadiumShared
import os.lock

/// External-lock box keyed by ObjectIdentifier(of: viewModel).
private final class EPUBReadAloudIndexBox: @unchecked Sendable {
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

private let epubReadAloudIndexBox = EPUBReadAloudIndexBox()

extension EPUBReaderViewModel {

    /// Index of the sentence currently being read aloud, or `nil` when no
    /// session is active. The setter touches an existing tracked field
    /// (`theme`) to wake @Observable trackers.
    public var currentReadAloudPassageIndex: Int? {
        get { epubReadAloudIndexBox.get(ObjectIdentifier(self)) }
        set {
            epubReadAloudIndexBox.set(ObjectIdentifier(self), newValue)
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
