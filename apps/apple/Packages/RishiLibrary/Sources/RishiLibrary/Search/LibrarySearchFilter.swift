import Foundation
import RishiCore

/// Pure-data filter for library search. Used by `LibraryViewModel` (Plan 04-06)
/// after debouncing the `.searchable(...)` binding from `LibrarySearchable`
/// (this plan).
///
/// Zero SwiftUI: Foundation + RishiCore only — so the filter can be unit-tested
/// in <10ms on every commit without dragging in the UI test harness.
public enum LibrarySearchFilter {

    /// Returns the subset of `books` whose title OR author contains `query`
    /// (case-insensitive, diacritic-insensitive, locale-aware). Whitespace-only
    /// or empty `query` returns the input unchanged.
    public static func filter(books: [Book], query: String) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        return books.filter { book in
            if matches(book.title, query: trimmed) { return true }
            if let author = book.author, matches(author, query: trimmed) { return true }
            return false
        }
    }

    /// Foundation's `localizedStandardContains` is the case-folding + diacritic
    /// folding + locale-aware "search-as-you-type" primitive Apple uses in
    /// Finder + Spotlight. No custom Unicode work needed.
    private static func matches(_ haystack: String, query: String) -> Bool {
        haystack.localizedStandardContains(query)
    }
}
