import SwiftUI
import RishiCore
import RishiUIKit

/// Top-level Library screen. Pure SwiftUI; view-model wiring in Plan 04-06.
///
/// LibraryView is a function of its inputs — no `@State`, no `@Environment`.
/// Plan 04-05 will add `.searchable(...)` and Plan 04-06 mounts this inside
/// a `NavigationStack` (or `NavigationSplitView` for iPad/Catalyst) fed by
/// `LibraryViewModel`.
public struct LibraryView: View {

    public let books: [Book]
    public let readingNow: [ReadingNowEntry]
    public let positionLookup: (BookID) -> Position?
    public let coverURL: (Book) -> URL?
    public let onOpen: (Book) -> Void
    public let onDelete: (Book) -> Void

    public init(books: [Book],
                readingNow: [ReadingNowEntry],
                positionLookup: @escaping (BookID) -> Position?,
                coverURL: @escaping (Book) -> URL?,
                onOpen: @escaping (Book) -> Void,
                onDelete: @escaping (Book) -> Void) {
        self.books = books
        self.readingNow = readingNow
        self.positionLookup = positionLookup
        self.coverURL = coverURL
        self.onOpen = onOpen
        self.onDelete = onDelete
    }

    public var body: some View {
        Group {
            if books.isEmpty {
                LibraryEmptyStateView()
            } else {
                VStack(spacing: 0) {
                    if !readingNow.isEmpty {
                        ReadingNowShelf(
                            entries: readingNow,
                            coverURL: coverURL,
                            onOpen: onOpen
                        )
                        Divider().background(RishiColor.divider)
                    }
                    LibraryGrid(
                        books: books,
                        positionLookup: positionLookup,
                        coverURL: coverURL,
                        onOpen: onOpen,
                        onDelete: onDelete
                    )
                }
                .background(RishiColor.background)
            }
        }
        .navigationTitle("Library")
    }
}
