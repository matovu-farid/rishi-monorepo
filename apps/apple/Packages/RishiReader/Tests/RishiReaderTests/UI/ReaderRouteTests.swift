import Foundation
import Testing
import RishiCore
@testable import RishiReader

@Suite("ReaderRoute")
struct ReaderRouteTests {

    @Test func pdfRoutesAreHashableAndEqualForSameID() {
        let id = UUID()
        #expect(ReaderRoute.pdf(id) == ReaderRoute.pdf(id))
        #expect(ReaderRoute.pdf(id).hashValue == ReaderRoute.pdf(id).hashValue)
    }

    @Test func pdfAndEpubWithSameIDAreNotEqual() {
        let id = UUID()
        #expect(ReaderRoute.pdf(id) != ReaderRoute.epub(id))
    }

    @Test func idReturnsTheWrappedBookIDForAllCases() {
        let id = UUID()
        #expect(ReaderRoute.pdf(id).id == id)
        #expect(ReaderRoute.epub(id).id == id)
        #expect(ReaderRoute.unsupportedFormat(id).id == id)
    }

    @Test func bookIdReturnsTheWrappedBookIDForAllCases() {
        let id = UUID()
        #expect(ReaderRoute.pdf(id).bookId == id)
        #expect(ReaderRoute.epub(id).bookId == id)
        #expect(ReaderRoute.unsupportedFormat(id).bookId == id)
    }

    @Test func routeForBookMapsFormatsCorrectly() {
        let userId = UUID()
        let pdfBook = Book(userId: userId, title: "P", formatType: .pdf, fileURL: "p.pdf")
        let epubBook = Book(userId: userId, title: "E", formatType: .epub, fileURL: "e.epub")
        let mobiBook = Book(userId: userId, title: "M", formatType: .mobi, fileURL: "m.mobi")
        let azw3Book = Book(userId: userId, title: "A", formatType: .azw3, fileURL: "a.azw3")

        #expect(ReaderRoute.route(for: pdfBook) == .pdf(pdfBook.id))
        #expect(ReaderRoute.route(for: epubBook) == .epub(epubBook.id))
        #expect(ReaderRoute.route(for: mobiBook) == .unsupportedFormat(mobiBook.id))
        #expect(ReaderRoute.route(for: azw3Book) == .unsupportedFormat(azw3Book.id))
    }

    @Test func codableRoundTripsAcrossAllCases() throws {
        let id = UUID()
        let routes: [ReaderRoute] = [.pdf(id), .epub(id), .unsupportedFormat(id)]
        for route in routes {
            let data = try JSONEncoder().encode(route)
            let decoded = try JSONDecoder().decode(ReaderRoute.self, from: data)
            #expect(decoded == route)
        }
    }

    @Test func readerRouteIsSendable() {
        // Compile-only assertion: the type signature includes Sendable.
        func acceptsSendable<T: Sendable>(_ value: T) {}
        acceptsSendable(ReaderRoute.pdf(UUID()))
    }
}
