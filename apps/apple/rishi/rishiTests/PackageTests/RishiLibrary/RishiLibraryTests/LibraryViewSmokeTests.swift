@testable import rishi
import Testing
import Foundation
import SwiftUI



@Suite("LibraryView smoke tests")
@MainActor
struct LibraryViewSmokeTests {

    // MARK: - ReadingNowEntry inclusion rule (LIB-05)

    @Test("isInProgress excludes 0% (fresh) and 100% (finished)")
    func isInProgress_endpointsExcluded() {
        let bookId = UUID()
        #expect(!ReadingNowEntry.isInProgress(LibraryFixture.position(bookId: bookId, percent: 0.0)))
        #expect(!ReadingNowEntry.isInProgress(LibraryFixture.position(bookId: bookId, percent: 1.0)))
    }

    @Test("isInProgress includes anything strictly between 0 and 1")
    func isInProgress_midRangeIncluded() {
        let bookId = UUID()
        #expect(ReadingNowEntry.isInProgress(LibraryFixture.position(bookId: bookId, percent: 0.01)))
        #expect(ReadingNowEntry.isInProgress(LibraryFixture.position(bookId: bookId, percent: 0.5)))
        #expect(ReadingNowEntry.isInProgress(LibraryFixture.position(bookId: bookId, percent: 0.999)))
    }

    @Test("ReadingNowEntry derives id and percentComplete from its parts")
    func readingNowEntry_derivedAccessors() {
        let book = LibraryFixture.book(title: "T")
        let pos = LibraryFixture.position(bookId: book.id, percent: 0.42)
        let entry = ReadingNowEntry(book: book, position: pos)
        #expect(entry.id == book.id)
        #expect(entry.percentComplete == 0.42)
    }

    // MARK: - Stub-driven Reading Now derivation

    @Test("Stub readingNow includes only in-progress books")
    func stub_readingNow_filtersByInProgress() {
        let a = LibraryFixture.book(title: "Started")
        let b = LibraryFixture.book(title: "Fresh")
        let c = LibraryFixture.book(title: "Finished")
        let d = LibraryFixture.book(title: "Untouched")

        let stub = LibraryViewModelStub(
            books: [a, b, c, d],
            positions: [
                a.id: LibraryFixture.position(bookId: a.id, percent: 0.5),
                b.id: LibraryFixture.position(bookId: b.id, percent: 0.0),
                c.id: LibraryFixture.position(bookId: c.id, percent: 1.0)
                // d has no position
            ]
        )

        let ids = stub.readingNow.map(\.id)
        #expect(ids == [a.id])
    }

    // MARK: - View construction compiles (smoke)

    @Test("LibraryView constructs with empty inputs")
    func libraryView_emptyConstructs() {
        let stub = LibraryViewModelStub()
        _ = LibraryView(
            books: stub.books,
            positionLookup: stub.positionLookup,
            coverURL: stub.coverURL,
            onOpen: stub.onOpen,
            onDelete: stub.onDelete
        )
        #expect(stub.books.isEmpty)
    }

    @Test("LibraryView constructs with populated state including in-progress book")
    func libraryView_populatedConstructs() {
        let started = LibraryFixture.book(title: "In Progress", author: "Ada Lovelace")
        let untouched = LibraryFixture.book(title: "Untouched")
        let stub = LibraryViewModelStub(
            books: [started, untouched],
            positions: [
                started.id: LibraryFixture.position(bookId: started.id, percent: 0.25)
            ]
        )
        _ = LibraryView(
            books: stub.books,
            positionLookup: stub.positionLookup,
            coverURL: stub.coverURL,
            onOpen: stub.onOpen,
            onDelete: stub.onDelete
        )
        #expect(stub.readingNow.count == 1)
        #expect(stub.readingNow.first?.book.id == started.id)
    }

    // MARK: - Sub-view construction (smoke)

    @Test("ReadingNowShelf, LibraryGrid, LibraryEmptyStateView, BookCoverImageView all construct")
    func subViews_construct() {
        let book = LibraryFixture.book(title: "X")
        let pos = LibraryFixture.position(bookId: book.id, percent: 0.3)
        let entry = ReadingNowEntry(book: book, position: pos)
        _ = ReadingNowShelf(entries: [entry], coverURL: { _ in nil }, onOpen: { _ in })
        _ = LibraryGrid(
            books: [book],
            positionLookup: { _ in pos },
            coverURL: { _ in nil },
            onOpen: { _ in },
            onDelete: { _ in }
        )
        _ = LibraryEmptyStateView()
        _ = BookCoverImageView(book: book, coverURL: nil)
        #expect(Bool(true))
    }

    // MARK: - Callback round-trip on stub

    @Test("Stub records onOpen and onDelete invocations")
    func stub_recordsCallbacks() {
        let book = LibraryFixture.book(title: "Cb")
        let stub = LibraryViewModelStub(books: [book])
        stub.onOpen(book)
        stub.onDelete(book)
        #expect(stub.openedBooks.map(\.id) == [book.id])
        #expect(stub.deletedBooks.map(\.id) == [book.id])
    }
}
