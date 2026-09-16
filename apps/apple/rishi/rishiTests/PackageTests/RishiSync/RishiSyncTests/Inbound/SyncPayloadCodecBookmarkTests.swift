@testable import rishi
import Testing
import Foundation




/// Phase 37 Plan 37-08 — SyncPayloadCodec bookmark arm.
///
/// Locks the canonical bookmark wire shape (37-07 worker half) byte-for-byte:
///   - payload snake_case keys: `id`, `book_id`, `locator`, `label`, `snippet`,
///     `created_at`.
///   - `created_at` inside the payload is an ISO8601 STRING (`.iso8601`), NOT a
///     number — the envelope `updated_at` is the seconds-since-2001 numeric the
///     WorkerClient owns separately.
///   - `encodeBookmark -> decodeBookmark` round-trips every field incl. nil
///     label/nil snippet.
///   - The wire-format bump to sync-v2 does NOT regress prior sync-v1 payloads:
///     a highlight + position payload still decode.
@Suite("SyncPayloadCodec — bookmark", .serialized)
struct SyncPayloadCodecBookmarkTests {

    @Test("chapter index codec preserves content version and source order")
    func chapterIndexRoundTrip() throws {
        let index = ChapterIndex(
            bookID: UUID(), contentVersion: "content-v1", status: .ready,
            modelIdentifier: "model", modelVersion: "1",
            progress: .init(completed: 2, total: 2),
            chapters: [
                .init(id: "chapter-2", name: "Two", summary: "Second", sourcePosition: 1),
                .init(id: "chapter-1", name: "One", summary: "First", sourcePosition: 0),
            ], updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let payload = try SyncPayloadCodec.encodeChapterIndex(index)
        let decoded = try SyncPayloadCodec.decodeChapterIndex(payload, fallbackUpdatedAt: index.updatedAt)
        #expect(decoded == index)
        #expect(decoded.chapters.map(\.sourcePosition) == [1, 0])
    }

    @Test("chapter index decoder accepts legacy children without source_position")
    func chapterIndexLegacySourcePosition() throws {
        let bookID = UUID()
        let body = """
        {"id":"\(UUID().uuidString)","book_id":"\(bookID.uuidString)","content_version":"v1","status":"ready","model_identifier":"m","model_version":"1","progress":{"completed":1,"total":1},"chapters":[{"id":"c","name":"C","summary":"S"}]}
        """
        let decoded = try SyncPayloadCodec.decodeChapterIndex(SyncOpaqueJSON(data: Data(body.utf8)), fallbackUpdatedAt: Date())
        #expect(decoded.chapters.first?.sourcePosition == 0)
    }

    @Test("chapter_index is a first-class sync entity kind")
    func entityKindChapterIndex() {
        #expect(SyncEntityKind(rawValue: "chapter_index") == .chapterIndex)
        #expect(SyncEntityKind.allCases.contains(.chapterIndex))
    }

    @Test("decodeBook accepts normalized pull metadata without a local file path")
    func decodeBookPullPayload() throws {
        let id = UUID()
        let owner = UUID()
        let body = """
        {"id":"\(id.uuidString)","user_id":"\(owner.uuidString)","title":"Remote","author":"A","format_type":"pdf","added_at":"2026-07-29T00:00:00Z","file_r2_key":"books/session/\(id.uuidString).pdf","current_page":7,"last_progress_percent":0.5}
        """
        let book = try SyncPayloadCodec.decodeBook(SyncOpaqueJSON(data: Data(body.utf8)), fallbackAddedAt: Date())
        #expect(book.id == id)
        #expect(book.formatType == .pdf)
        #expect(book.fileURL == "")
    }

    @Test("decodeBookR2Key accepts ISO8601 book created_at")
    func decodeBookR2KeyAcceptsISO8601CreatedAt() throws {
        let id = UUID()
        let body = """
        {"id":"\(id.uuidString)","title":"Remote","format_type":"pdf","created_at":"2026-07-29T00:00:00Z","file_r2_key":"books/session/\(id.uuidString).pdf"}
        """

        let key = try SyncPayloadCodec.decodeBookR2Key(
            SyncOpaqueJSON(data: Data(body.utf8))
        )

        #expect(key == "books/session/\(id.uuidString).pdf")
    }

    @Test("decodeBookR2Key ignores unrelated legacy numeric dates")
    func decodeBookR2KeyIgnoresUnrelatedLegacyNumericDates() throws {
        let body = #"{"file_r2_key":"books/legacy/book.pdf","created_at":123.0,"opened_at":456.0}"#

        let key = try SyncPayloadCodec.decodeBookR2Key(
            SyncOpaqueJSON(data: Data(body.utf8))
        )

        #expect(key == "books/legacy/book.pdf")
    }

    @Test("decodeBookR2Key rejects a non-string R2 key")
    func decodeBookR2KeyRejectsNonStringValue() {
        let body = #"{"file_r2_key":123}"#

        #expect(throws: DecodingError.self) {
            try SyncPayloadCodec.decodeBookR2Key(
                SyncOpaqueJSON(data: Data(body.utf8))
            )
        }
    }

    @Test("book chapter index content version round-trips and remains optional")
    func bookChapterIndexContentVersionRoundTrip() throws {
        let book = Book(
            userId: UUID(),
            title: "Remote",
            formatType: .epub,
            fileURL: "Books/book.epub",
            chapterIndexContentVersion: "chapter-v3"
        )
        let payload = try SyncPayloadCodec.encodeBook(book)
        let decoded = try SyncPayloadCodec.decodeBook(payload, fallbackAddedAt: book.addedAt)
        #expect(decoded.chapterIndexContentVersion == "chapter-v3")

        let legacy = SyncOpaqueJSON(data: Data("{\"id\":\"\(book.id.uuidString)\",\"title\":\"Legacy\",\"format_type\":\"epub\"}".utf8))
        #expect(try SyncPayloadCodec.decodeBook(legacy, fallbackAddedAt: book.addedAt).chapterIndexContentVersion == nil)
    }

    @Test("encodeBookmark -> decodeBookmark round-trips all fields")
    func roundTripAllFields() throws {
        let bookmark = Bookmark(
            id: UUID(),
            bookId: UUID(),
            locator: "epub-v1:cfi:/6/4[chap01]!/4/2/2",
            label: "Chapter One",
            snippet: "It was a bright cold day in April.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let payload = try SyncPayloadCodec.encodeBookmark(bookmark)
        let decoded = try SyncPayloadCodec.decodeBookmark(payload, fallbackCreatedAt: Date(timeIntervalSince1970: 0))

        #expect(decoded.id == bookmark.id)
        #expect(decoded.bookId == bookmark.bookId)
        #expect(decoded.locator == bookmark.locator)
        #expect(decoded.label == bookmark.label)
        #expect(decoded.snippet == bookmark.snippet)
        #expect(decoded.createdAt == bookmark.createdAt)
    }

    @Test("encodeBookmark -> decodeBookmark round-trips with nil label + nil snippet")
    func roundTripNilOptionals() throws {
        let bookmark = Bookmark(
            id: UUID(),
            bookId: UUID(),
            locator: "pdf-v1:page:42",
            label: nil,
            snippet: nil,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000)
        )

        let payload = try SyncPayloadCodec.encodeBookmark(bookmark)
        let decoded = try SyncPayloadCodec.decodeBookmark(payload, fallbackCreatedAt: Date(timeIntervalSince1970: 0))

        #expect(decoded.id == bookmark.id)
        #expect(decoded.locator == "pdf-v1:page:42")
        #expect(decoded.label == nil)
        #expect(decoded.snippet == nil)
        #expect(decoded.createdAt == bookmark.createdAt)
    }

    @Test("Encoded payload uses snake_case keys + ISO8601 created_at string")
    func wireShapeSnakeCaseAndISO8601() throws {
        let bookmark = Bookmark(
            id: UUID(),
            bookId: UUID(),
            locator: "epub-v1:cfi",
            label: "L",
            snippet: "S",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let payload = try SyncPayloadCodec.encodeBookmark(bookmark)

        let json = try #require(
            try JSONSerialization.jsonObject(with: payload.data) as? [String: Any]
        )
        // snake_case keys present (mirror the worker contract).
        #expect(json["book_id"] != nil)
        #expect(json["locator"] != nil)
        #expect(json["snippet"] != nil)
        #expect(json["created_at"] != nil)
        // book_id / locator NOT camelCased.
        #expect(json["bookId"] == nil)

        // created_at is an ISO8601 STRING, not a number.
        let createdAt = try #require(json["created_at"] as? String)
        #expect(createdAt.contains("T"))
        #expect(createdAt.contains("Z") || createdAt.contains("+"))
        // The string round-trips through an ISO8601 formatter.
        let formatter = ISO8601DateFormatter()
        #expect(formatter.date(from: createdAt) != nil)
    }

    @Test("decodeBookmark falls back to fallbackCreatedAt when created_at absent")
    func decodeFallbackCreatedAt() throws {
        // A payload missing created_at (e.g. a future shape) must not throw —
        // it falls back to the envelope timestamp, mirroring decodeHighlight.
        let bookId = UUID()
        let id = UUID()
        let body = """
        { "id": "\(id.uuidString)", "book_id": "\(bookId.uuidString)", "locator": "pdf-v1:page:1", "label": null, "snippet": null }
        """
        let payload = SyncOpaqueJSON(data: Data(body.utf8))
        let fallback = Date(timeIntervalSince1970: 1_234_567_890)

        let decoded = try SyncPayloadCodec.decodeBookmark(payload, fallbackCreatedAt: fallback)
        #expect(decoded.id == id)
        #expect(decoded.bookId == bookId)
        #expect(decoded.createdAt == fallback)
    }

    // MARK: - No-regression: sync-v1 payloads still decode after the wire bump.

    @Test("No regression: a sync-v1 highlight payload still decodes")
    func syncV1HighlightStillDecodes() throws {
        let highlight = Highlight(
            bookId: UUID(),
            locatorStart: "epub-v1:cfi",
            locatorEnd: "epub-v1:cfi",
            color: .yellow,
            text: "legacy",
            createdAt: Date(timeIntervalSince1970: 1_650_000_000)
        )
        let payload = try SyncPayloadCodec.encodeHighlight(highlight)
        let decoded = try SyncPayloadCodec.decodeHighlight(payload, fallbackCreatedAt: Date(timeIntervalSince1970: 0))
        #expect(decoded.id == highlight.id)
        #expect(decoded.text == "legacy")
        #expect(decoded.createdAt == highlight.createdAt)
    }

    @Test("No regression: a sync-v1 position payload still decodes")
    func syncV1PositionStillDecodes() throws {
        let position = Position(
            bookId: UUID(),
            locator: "pdf-v1:page:3",
            percentComplete: 0.1,
            updatedAt: Date(timeIntervalSince1970: 1_640_000_000)
        )
        let payload = try SyncPayloadCodec.encodePosition(position)
        let decoded = try SyncPayloadCodec.decodePosition(payload, fallbackUpdatedAt: Date(timeIntervalSince1970: 0))
        #expect(decoded.id == position.id)
        #expect(decoded.locator == "pdf-v1:page:3")
        #expect(decoded.updatedAt == position.updatedAt)
    }

    @Test("SyncEntityKind(rawValue: bookmark) resolves + stays CaseIterable")
    func entityKindBookmark() {
        #expect(SyncEntityKind(rawValue: "bookmark") == .bookmark)
        #expect(SyncEntityKind.allCases.contains(.bookmark))
    }
}
