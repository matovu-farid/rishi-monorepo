@testable import rishi
import Foundation
import Testing


@Suite("Codable round-trip")
struct CodableRoundTripTests {

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }

    @Test func bookRoundTrips() throws {
        let userId = UUID()
        let book = Book(
            id: UUID(),
            userId: userId,
            title: "The Hobbit",
            author: "J.R.R. Tolkien",
            formatType: .epub,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            openedAt: Date(timeIntervalSince1970: 1_700_100_000),
            fileURL: "books/the-hobbit.epub",
            coverPath: "covers/the-hobbit.png",
            positionId: UUID(),
            conversationId: UUID()
        )
        let decoded = try roundTrip(book)
        #expect(decoded == book)
    }

    @Test func positionRoundTrips() throws {
        let position = Position(
            bookId: UUID(),
            locator: "epubcfi(/6/4!/4/10/2,1:0,1:8)",
            percentComplete: 0.42,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try roundTrip(position)
        #expect(decoded == position)
    }

    @Test func highlightRoundTrips() throws {
        let highlight = Highlight(
            bookId: UUID(),
            locatorStart: "cfi-start",
            locatorEnd: "cfi-end",
            color: .yellow,
            text: "It does not do to leave a live dragon out of your calculations.",
            note: "Quotable.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try roundTrip(highlight)
        #expect(decoded == highlight)
    }

    @Test func conversationRoundTrips() throws {
        let conversation = Conversation(
            userId: UUID(),
            bookId: UUID(),
            title: "About chapter 3",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let decoded = try roundTrip(conversation)
        #expect(decoded == conversation)
    }

    @Test func messageRoundTrips() throws {
        let message = Message(
            conversationId: UUID(),
            role: .assistant,
            content: "Bilbo Baggins is the protagonist.",
            toolCalls: "{\"name\":\"search\",\"args\":{}}",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try roundTrip(message)
        #expect(decoded == message)
    }

    @Test func userRoundTrips() throws {
        let user = User(
            email: "matovu90@gmail.com",
            displayName: "Farid",
            avatarURL: URL(string: "https://example.com/avatar.png"),
            hasPro: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoded = try roundTrip(user)
        #expect(decoded == user)
    }

    @Test func bookFormatRawValuesIncludeMobiAndAzw3() {
        let formats = BookFormat.allCases.map(\.rawValue)
        #expect(formats.contains("epub"))
        #expect(formats.contains("pdf"))
        #expect(formats.contains("mobi"))
        #expect(formats.contains("azw3"))
    }

    @Test func highlightColorAllFourColors() {
        #expect(HighlightColor.allCases.count == 4)
        let raws = HighlightColor.allCases.map(\.rawValue)
        #expect(raws.contains("yellow"))
        #expect(raws.contains("green"))
        #expect(raws.contains("blue"))
        #expect(raws.contains("pink"))
    }
}
