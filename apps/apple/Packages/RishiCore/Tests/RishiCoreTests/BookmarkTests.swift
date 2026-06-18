import Foundation
import Testing
@testable import RishiCore

@Suite("Bookmark model + store contract")
struct BookmarkTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    @Test func bookmarkRoundTripsWithAllFields() throws {
        let bookmark = Bookmark(
            bookId: UUID(),
            locator: "{\"format\":\"epub-bmk-v1\",\"readiumLocator\":\"{}\"}",
            label: "Chapter 3",
            snippet: "It does not do to leave a live dragon out of your calculations.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try roundTrip(bookmark)
        #expect(decoded == bookmark)
    }

    @Test func bookmarkRoundTripsWithNilOptionals() throws {
        let bookmark = Bookmark(
            bookId: UUID(),
            locator: "{\"format\":\"pdf-bmk-v1\",\"page\":12}",
            label: nil,
            snippet: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try roundTrip(bookmark)
        #expect(decoded == bookmark)
        #expect(decoded.label == nil)
        #expect(decoded.snippet == nil)
    }
}
