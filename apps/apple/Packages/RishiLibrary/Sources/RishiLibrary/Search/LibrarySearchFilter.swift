import Foundation
import RishiCore

/// Pure-data filter for library search. Used by `LibraryViewModel` (Plan 04-06)
/// after debouncing the `.searchable(...)` binding from `LibrarySearchable`
/// (this plan).
///
/// Zero SwiftUI: Foundation + RishiCore only — so the filter can be unit-tested
/// in <10ms on every commit without dragging in the UI test harness.
public enum LibrarySearchFilter {

    /// Returns the subset of `books` whose `title`, `author`, OR filename
    /// (`fileURL` basename) contains every whitespace-separated token of
    /// `query`. Matching is case-insensitive + diacritic-insensitive via
    /// `localizedStandardContains`.
    ///
    /// Tokenisation rationale: the import path falls back to a
    /// filename-derived title when the embedded metadata is missing
    /// (`1751655520501062500_alice` → "1751655520501062500 alice"), and we
    /// want "alice wonder" to match "Alice in Wonderland" even though the
    /// tokens are non-contiguous. We AND the tokens across all three fields
    /// (title OR author OR filename can satisfy each token) so the user does
    /// not have to type the title in the canonical word order.
    ///
    /// Whitespace-only or empty `query` returns the input unchanged.
    public static func filter(books: [Book], query: String) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return books }
        return books.filter { book in
            let filename = filenameHaystack(for: book)
            // AND across tokens: every token must hit at least one field.
            // OR across fields: any of {title, author, filename} can satisfy
            // a given token.
            for token in tokens {
                let titleHit = matches(book.title, query: token)
                let authorHit = book.author.map { matches($0, query: token) } ?? false
                let filenameHit = matches(filename, query: token)
                if !(titleHit || authorHit || filenameHit) { return false }
            }
            return true
        }
    }

    /// Foundation's `localizedStandardContains` is the case-folding + diacritic
    /// folding + locale-aware "search-as-you-type" primitive Apple uses in
    /// Finder + Spotlight. No custom Unicode work needed.
    private static func matches(_ haystack: String, query: String) -> Bool {
        haystack.localizedStandardContains(query)
    }

    /// Strips the directory and extension off `book.fileURL`, then swaps
    /// underscores / hyphens for spaces so e.g.
    /// `Books/<uuid>/1751655520501062500_alice.epub` becomes
    /// `1751655520501062500 alice` — which makes "alice" actually match a
    /// book whose embedded metadata is missing.
    private static func filenameHaystack(for book: Book) -> String {
        let name = (book.fileURL as NSString).lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        return stem
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}
