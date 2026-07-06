import Foundation
import RishiCore
import RishiCore

/// Single source of truth for re-decoding a `SyncOpaqueJSON.data` blob into
/// a concrete RishiCore model and vice-versa.
///
/// Wire format (sync-v1) is snake_case to match the existing RishiDB column
/// names + the worker's `sync_metadata` / R2 payload shape. Wire DTOs are
/// declared as private nested structs with explicit `CodingKeys` so the
/// in-memory RishiCore models remain camelCase but the bytes on the wire stay
/// stable for forward compat.
///
/// Schema changes require:
///   1. Bumping `RishiSync.wireFormat` to `sync-v2`.
///   2. Adding a decoder fallback that still accepts sync-v1.
enum SyncPayloadCodec {

    enum CodecError: Error, Sendable, Equatable {
        case unsupportedKind(String)
        case decodeFailed(kind: String, underlying: String)
    }

    // MARK: - Decoders

    /// Decode a position payload. `fallbackUpdatedAt` is used if the wire
    /// payload omits `updated_at` (server defaults to the change envelope's
    /// timestamp).
    public static func decodePosition(_ payload: SyncOpaqueJSON, fallbackUpdatedAt: Date) throws -> Position {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let wire = try decoder.decode(WirePosition.self, from: payload.data)
            return Position(
                id: wire.id,
                bookId: wire.bookId,
                locator: wire.locator,
                percentComplete: wire.percentComplete,
                updatedAt: wire.updatedAt ?? fallbackUpdatedAt
            )
        } catch {
            throw CodecError.decodeFailed(kind: "position", underlying: String(describing: error))
        }
    }

    public static func decodeHighlight(_ payload: SyncOpaqueJSON, fallbackCreatedAt: Date) throws -> Highlight {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let wire = try decoder.decode(WireHighlight.self, from: payload.data)
            return Highlight(
                id: wire.id,
                bookId: wire.bookId,
                locatorStart: wire.locatorStart,
                locatorEnd: wire.locatorEnd,
                color: wire.color,
                text: wire.text,
                note: wire.note,
                createdAt: wire.createdAt ?? fallbackCreatedAt
            )
        } catch {
            throw CodecError.decodeFailed(kind: "highlight", underlying: String(describing: error))
        }
    }

    /// Decode a bookmark payload (sync-v2). `fallbackCreatedAt` is used if the
    /// wire payload omits `created_at` (mirrors `decodeHighlight`).
    public static func decodeBookmark(_ payload: SyncOpaqueJSON, fallbackCreatedAt: Date) throws -> Bookmark {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let wire = try decoder.decode(WireBookmark.self, from: payload.data)
            return Bookmark(
                id: wire.id,
                bookId: wire.bookId,
                locator: wire.locator,
                label: wire.label,
                snippet: wire.snippet,
                createdAt: wire.createdAt ?? fallbackCreatedAt
            )
        } catch {
            throw CodecError.decodeFailed(kind: "bookmark", underlying: String(describing: error))
        }
    }

    public static func decodeBook(_ payload: SyncOpaqueJSON, fallbackAddedAt: Date) throws -> Book {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let wire = try decoder.decode(WireBook.self, from: payload.data)
            return Book(
                id: wire.id,
                userId: wire.userId,
                title: wire.title,
                author: wire.author,
                formatType: wire.formatType,
                addedAt: wire.addedAt ?? fallbackAddedAt,
                openedAt: wire.openedAt,
                fileURL: wire.fileURL,
                coverPath: wire.coverPath,
                positionId: wire.positionId,
                conversationId: wire.conversationId
            )
        } catch {
            throw CodecError.decodeFailed(kind: "book", underlying: String(describing: error))
        }
    }

    // MARK: - Encoders (outbound push)

    public static func encodePosition(_ position: Position) throws -> SyncOpaqueJSON {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let wire = WirePosition(
            id: position.id,
            bookId: position.bookId,
            locator: position.locator,
            percentComplete: position.percentComplete,
            updatedAt: position.updatedAt
        )
        return SyncOpaqueJSON(data: try encoder.encode(wire))
    }

    public static func encodeHighlight(_ highlight: Highlight) throws -> SyncOpaqueJSON {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let wire = WireHighlight(
            id: highlight.id,
            bookId: highlight.bookId,
            locatorStart: highlight.locatorStart,
            locatorEnd: highlight.locatorEnd,
            color: highlight.color,
            text: highlight.text,
            note: highlight.note,
            createdAt: highlight.createdAt
        )
        return SyncOpaqueJSON(data: try encoder.encode(wire))
    }

    public static func encodeBookmark(_ bookmark: Bookmark) throws -> SyncOpaqueJSON {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let wire = WireBookmark(
            id: bookmark.id,
            bookId: bookmark.bookId,
            locator: bookmark.locator,
            label: bookmark.label,
            snippet: bookmark.snippet,
            createdAt: bookmark.createdAt
        )
        return SyncOpaqueJSON(data: try encoder.encode(wire))
    }

    public static func encodeBook(_ book: Book) throws -> SyncOpaqueJSON {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let wire = WireBook(
            id: book.id,
            userId: book.userId,
            title: book.title,
            author: book.author,
            formatType: book.formatType,
            addedAt: book.addedAt,
            openedAt: book.openedAt,
            fileURL: book.fileURL,
            coverPath: book.coverPath,
            positionId: book.positionId,
            conversationId: book.conversationId
        )
        return SyncOpaqueJSON(data: try encoder.encode(wire))
    }

    // MARK: - Wire types (snake_case bridges)

    private struct WirePosition: Codable {
        let id: PositionID
        let bookId: BookID
        let locator: String
        let percentComplete: Double
        let updatedAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case bookId = "book_id"
            case locator
            case percentComplete = "percent_complete"
            case updatedAt = "updated_at"
        }
    }

    private struct WireHighlight: Codable {
        let id: HighlightID
        let bookId: BookID
        let locatorStart: String
        let locatorEnd: String
        let color: HighlightColor
        let text: String
        let note: String?
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case bookId = "book_id"
            case locatorStart = "locator_start"
            case locatorEnd = "locator_end"
            case color
            case text
            case note
            case createdAt = "created_at"
        }
    }

    private struct WireBookmark: Codable {
        let id: BookmarkID
        let bookId: BookID
        let locator: String
        let label: String?
        let snippet: String?
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case id
            case bookId = "book_id"
            case locator
            case label
            case snippet
            case createdAt = "created_at"
        }
    }

    private struct WireBook: Codable {
        let id: BookID
        let userId: UserID
        let title: String
        let author: String?
        let formatType: BookFormat
        let addedAt: Date?
        let openedAt: Date?
        let fileURL: String
        let coverPath: String?
        let positionId: PositionID?
        let conversationId: ConversationID?

        enum CodingKeys: String, CodingKey {
            case id
            case userId = "user_id"
            case title
            case author
            case formatType = "format_type"
            case addedAt = "added_at"
            case openedAt = "opened_at"
            case fileURL = "file_url"
            case coverPath = "cover_path"
            case positionId = "position_id"
            case conversationId = "conversation_id"
        }
    }
}
