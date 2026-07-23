import Foundation

// MARK: - POST /api/voice-sessions

/// Starts a Rishi voice session per the no-card-credit-trial spec's "Voice
/// flow" step 1–2: the ledger verifies the applicable trial/plan allowance,
/// creates a Rishi session ID + single-use registration nonce, records the
/// session cap, and mints an OpenAI Realtime client secret — all in one
/// synchronous round trip (`2026-07-17-voice-sessions-route.md`).
///
/// Body fields are the same optional book-context shape
/// `RealtimeClientSecretsEndpoint` (`RealtimeAPI.swift`) already sends —
/// duplicated here (rather than shared) because the two endpoints are
/// independent wire contracts on the worker side (separate Hono routes,
/// separate Zod schemas) even though the payload shape happens to match
/// today.
public struct CreateVoiceSessionEndpoint: WorkerEndpointWithBody {
    public typealias Response = CreatedVoiceSession

    public let method: HTTPMethod = .POST
    public let path: String = "/api/voice-sessions"
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

    /// Sparse on encode — nil fields are omitted, so a book-less
    /// `CreateVoiceSessionEndpoint()` emits `{}`, matching the worker's
    /// `CreateVoiceSessionBodySchema.partial()`.
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

    /// Wire shape is already flat camelCase
    /// (`{ rishiSessionId, nonce, clientSecret, capIntervals }`) per
    /// `2026-07-17-voice-sessions-route.md`'s "Exports for downstream
    /// plans" — no custom `CodingKeys` needed.
    public struct CreatedVoiceSession: Decodable, Sendable, Equatable {
        public let rishiSessionId: String
        public let nonce: String
        public let clientSecret: String
        public let capIntervals: Int
    }
}

// MARK: - POST /api/voice-sessions/:id/register-call

/// Registers the OpenAI `call_id` the vendored Swift Realtime connector
/// captured from the `Location` header of its WebRTC call-creation response,
/// per the no-card-credit-trial spec's "Voice flow" step 3–5. `:id` is the
/// `rishiSessionId` `CreateVoiceSessionEndpoint` returned.
///
/// Every non-2xx response from this endpoint means the caller MUST close the
/// just-opened OpenAI WebRTC connection and show a retryable error — see
/// `2026-07-17-voice-sessions-route.md`'s "Exports for downstream plans"
/// table (this plan's `VoiceSessionRegistrationFailure` classifies exactly
/// that table).
public struct RegisterVoiceCallEndpoint: WorkerEndpointWithBody {
    public typealias Response = RegisterCallResponse

    public let method: HTTPMethod = .POST
    public let path: String
    public let body: Body

    public init(rishiSessionId: String, callId: String, nonce: String) {
        self.path = "/api/voice-sessions/\(rishiSessionId)/register-call"
        self.body = Body(callId: callId, nonce: nonce)
    }

    public struct Body: Encodable, Sendable, Equatable {
        public let callId: String
        public let nonce: String
    }

    public struct RegisterCallResponse: Decodable, Sendable, Equatable {
        public let ok: Bool
    }
}

// MARK: - POST /api/voice-sessions/end-active

/// Force-ends whichever voice session the ledger considers live for this user.
/// Used before create when local teardown may have left a registered row active.
public struct EndActiveVoiceSessionEndpoint: WorkerEndpoint {
    public typealias Response = EndActiveVoiceSessionResponse

    public let method: HTTPMethod = .POST
    public let path: String = "/api/voice-sessions/end-active"

    public init() {}

    public struct EndActiveVoiceSessionResponse: Decodable, Sendable, Equatable {
        public let ok: Bool
        public let rishiSessionId: String?
    }
}

// MARK: - POST /api/voice-sessions/:id/end

/// Client hangup for a Rishi voice session. Called on intentional End so the
/// ledger goes terminal promptly rather than burning intervals until idle
/// timeout. Also unblocks create after abandoned pending_registration.
public struct EndVoiceSessionEndpoint: WorkerEndpoint {
    public typealias Response = EndVoiceSessionResponse

    public let method: HTTPMethod = .POST
    public let path: String

    public init(rishiSessionId: String) {
        self.path = "/api/voice-sessions/\(rishiSessionId)/end"
    }

    public struct EndVoiceSessionResponse: Decodable, Sendable, Equatable {
        public let ok: Bool
    }
}
