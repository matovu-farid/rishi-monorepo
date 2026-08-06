import Foundation

/// Decoded shape of a 4xx error response from the Rishi worker.
/// Wire format mirrors electron's IPC error convention enriched with a
/// structured envelope, per Phase 2 requirement API-03.
///
/// Wire JSON:
/// ```json
/// { "error": { "code": "forbidden", "message": "...", "details": { "reason": "..." } } }
/// ```
struct ErrorEnvelope: Codable, Sendable, Hashable {
    public let error: Inner

    public struct Inner: Codable, Sendable, Hashable {
        public let code: String
        public let message: String
        public let details: [String: String]?

        public init(code: String, message: String, details: [String: String]? = nil) {
            self.code = code
            self.message = message
            self.details = details
        }
    }

    public init(error: Inner) {
        self.error = error
    }

    /// Convenience accessors so call sites don't have to drill through `.error.`.
    public var code: String    { error.code }
    public var message: String { error.message }
    public var details: [String: String]? { error.details }
}

/// Decoded shape of the flat `{ "error": "<message>", "code": "<CODE>" }`
/// 4xx/5xx error body used by the voice-session routes
/// (`workers/worker/src/routes/voice-session-errors.ts` and
/// `workers/worker/src/routes/voice-sessions.ts`'s own 400/502 responses) —
/// distinct from the nested `ErrorEnvelope` shape most other worker routes
/// use. `WorkerClient` tries `ErrorEnvelope` first, then this, before
/// falling back to a generic code. See
/// `2026-07-17-voice-session-flow-wiring.md` Task 1.
struct FlatErrorEnvelope: Codable, Sendable, Hashable {
    let error: String
    let code: String
    let allowanceKind: String?

    enum CodingKeys: String, CodingKey {
        case error
        case code
        case allowanceKind = "allowance_kind"
    }
}
