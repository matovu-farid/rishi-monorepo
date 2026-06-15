//
//  NavigationLazyBook.swift
//  rishi
//

import SwiftUI
import RishiCore

/// Phase 18 Plan 18-01 — async-resolve a `Book` from a `BookID` for use
/// inside a `NavigationStack` destination. The path itself only carries
/// `ReaderRoute` (Codable + BookID) so scene restoration stays primitive.
/// This helper performs the `bookStore.book(_:)` lookup on appear,
/// rendering a `ProgressView` until the book resolves.
struct NavigationLazyBook<Content: View>: View {
    let bookId: BookID
    let bookStore: any BookStore
    let content: (Book) -> Content

    @State private var book: Book?

    /// Phase 20 perf — accept an optional `hint` so call sites that
    /// already have the resolved `Book` (library tap, Mac intent, legacy
    /// scene-restore B) can seed `@State` and skip the
    /// `bookStore.book(_:)` round-trip entirely. The fallback DB read
    /// still runs whenever the hint is nil (cold launch scene restore
    /// path), so existing behaviour is preserved.
    init(bookId: BookID,
         hint: Book? = nil,
         bookStore: any BookStore,
         @ViewBuilder content: @escaping (Book) -> Content) {
        self.bookId = bookId
        self.bookStore = bookStore
        self.content = content
        self._book = State(initialValue: hint)
    }

    var body: some View {
        Group {
            if let book {
                content(book)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: bookId) {
            if book == nil {
                book = try? await bookStore.book(bookId)
            }
        }
    }
}
