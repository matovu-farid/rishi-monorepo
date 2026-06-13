//
//  SentenceSplitter.swift
//  rishi (Phase 8 plan 08-06)
//
//  Pure-Swift sentence segmentation used by ReaderTTSBridge to chunk a page
//  (PDF) or resource (EPUB) of text into [Passage] for /api/audio/speech.
//
//  Uses Foundation's `String.enumerateSubstrings(in:options: .bySentences)`
//  — locale-aware, Unicode-correct, identical primitive to Apple's Notes /
//  Safari Reader text extraction. No CoreFoundation tokenizer needed.
//

import Foundation

enum SentenceSplitter {

    /// Splits `text` into sentence-sized fragments. Drops empty results and
    /// trims surrounding whitespace.
    ///
    /// - Behaviour:
    ///   - "Hello world. How are you?" → ["Hello world.", "How are you?"]
    ///   - Tolerates trailing whitespace, blank lines, and emoji.
    ///   - Empty / whitespace-only input → []
    nonisolated static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var sentences: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .localized]
        ) { substring, _, _, _ in
            guard let raw = substring else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sentences.append(trimmed)
            }
        }
        return sentences
    }
}
