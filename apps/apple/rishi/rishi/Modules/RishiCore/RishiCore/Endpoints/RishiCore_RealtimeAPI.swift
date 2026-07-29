import Foundation

// MARK: - Book context payload (Phase 25)

/// Outline of a book — title, author, chapter list — used by the assistant
/// to ground the system prompt before any tool call.
///
/// Shipped as part of `BookContextSnapshot` on the POST body of
/// `/api/realtime/client_secrets` so the worker (Plan 25-06) can render
/// `BOOK_CONTEXT_TOOL_SPEC` + `renderRealtimeInstructions(...)` from
/// `@rishi/shared` server-side. `chapters` is a flat list of chapter
/// titles in reading order; the assistant uses it to ground "where am I
/// in the book" questions without a tool call.
public struct BookOutlineDTO: Sendable, Equatable, Codable {
    public let title: String
    public let author: String?
    public let chapters: [String]

    public init(title: String, author: String?, chapters: [String]) {
        self.title = title
        self.author = author
        self.chapters = chapters
    }
}

/// Snapshot of the iOS reader's state at the moment a voice session starts.
///
/// The reader passes whatever it knows: which book, which page, the visible
/// page text, the outline, the active paragraph the user is reading. All
/// fields except `bookId` are optional — a session can start before a page
/// is open (e.g. from the library shell) and the snapshot then contains only
/// the book identifier.
///
/// Sent in the body of `POST /api/realtime/client_secrets`. The wire shape
/// uses snake_case (`book_id`, `current_page`, `page_text`,
/// `active_paragraph_text`); the Swift surface stays camelCase.
public struct BookContextSnapshot: Sendable, Equatable, Codable {
    public let bookId: UUID
    public let currentPage: Int?
    public let pageText: String?
    public let outline: BookOutlineDTO?
    public let activeParagraphText: String?

    public init(
        bookId: UUID,
        currentPage: Int? = nil,
        pageText: String? = nil,
        outline: BookOutlineDTO? = nil,
        activeParagraphText: String? = nil
    ) {
        self.bookId = bookId
        self.currentPage = currentPage
        self.pageText = pageText
        self.outline = outline
        self.activeParagraphText = activeParagraphText
    }

    private enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case currentPage = "current_page"
        case pageText = "page_text"
        case outline
        case activeParagraphText = "active_paragraph_text"
    }
}

// MARK: - POST /api/realtime/client_secrets

/// `POST /api/realtime/client_secrets` — mint an ephemeral OpenAI Realtime
/// client secret for direct WebRTC handoff (Phase 10), now with book-context
/// body fields (Phase 25).
///
/// The worker (Plan 25-06) uses the body to:
///   - tune VAD / locale-aware agent prompts via `language`
///   - render `BOOK_CONTEXT_TOOL_SPEC` + `renderRealtimeInstructions(...)`
///     from `@rishi/shared` so OpenAI gets a book-aware system prompt + the
///     `bookContext(queryText)` tool registered server-side
///
/// All body fields are optional — a default-constructed
/// `RealtimeClientSecretsEndpoint()` encodes to `{}` and reproduces the
/// pre-Phase-25 behavior (no book, no language hint).
///
/// The response shape (`{client_secret, session_id}`) is UNCHANGED — iOS
/// contract is stable.
public struct RealtimeClientSecretsEndpoint: WorkerEndpointWithBody {
    public typealias Response = ClientSecretResponse

    public let method: HTTPMethod = .POST
    public let path: String = "/api/realtime/client_secrets"
    public let requiresDataUseConsent = true
    public let body: Body

    public init(language: String? = nil, bookContext: BookContextSnapshot? = nil) {
        self.body = Body(
            language: language,
            bookId: bookContext?.bookId,
            currentPage: bookContext?.currentPage,
            pageText: bookContext?.pageText,
            outline: bookContext?.outline,
            activeParagraphText: bookContext?.activeParagraphText
        )
    }

    /// Body of the POST request. Sparse on encode — nil fields are omitted
    /// from the JSON, so `RealtimeClientSecretsEndpoint()` emits `{}`.
    /// CodingKeys map Swift camelCase to wire snake_case so the worker and
    /// iOS share a single source of truth for field names.
    public struct Body: Encodable, Sendable, Equatable {
        public let language: String?
        public let bookId: UUID?
        public let currentPage: Int?
        public let pageText: String?
        public let outline: BookOutlineDTO?
        public let activeParagraphText: String?

        enum CodingKeys: String, CodingKey {
            case language
            case bookId = "book_id"
            case currentPage = "current_page"
            case pageText = "page_text"
            case outline
            case activeParagraphText = "active_paragraph_text"
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            // Sparse encoding — omit nil fields rather than emit `null`. The
            // worker treats absent and null identically, but `{}` for the
            // default init keeps payloads minimal and tests deterministic.
            if let language { try container.encode(language, forKey: .language) }
            if let bookId { try container.encode(bookId, forKey: .bookId) }
            if let currentPage { try container.encode(currentPage, forKey: .currentPage) }
            if let pageText { try container.encode(pageText, forKey: .pageText) }
            if let outline { try container.encode(outline, forKey: .outline) }
            if let activeParagraphText {
                try container.encode(activeParagraphText, forKey: .activeParagraphText)
            }
        }
    }

    public struct ClientSecretResponse: Decodable, Sendable, Equatable {
        public let clientSecret: String
        public let sessionId: String

        enum CodingKeys: String, CodingKey {
            case clientSecret = "client_secret"
            case sessionId    = "session_id"
        }
    }
}
