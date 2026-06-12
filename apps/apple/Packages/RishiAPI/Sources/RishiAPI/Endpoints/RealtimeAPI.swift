import Foundation

// MARK: - GET /api/realtime/client_secrets

/// `GET /api/realtime/client_secrets?language=…` — mint an ephemeral
/// OpenAI Realtime client secret for direct WebRTC handoff (Phase 10).
///
/// The optional `language` argument lets the worker tune VAD / locale-aware
/// agent prompts. It's folded into the path string so plain ``WorkerEndpoint``
/// callers don't need a separate query-arg API on `WorkerClient`.
public struct RealtimeClientSecretsEndpoint: WorkerEndpoint {
    public typealias Response = ClientSecretResponse

    /// Optional `?language=` query. WorkerClient currently appends this to path
    /// when present; Phase 8/10 plans wire it through.
    public let language: String?

    public init(language: String? = nil) {
        self.language = language
    }

    public let method: HTTPMethod = .GET
    public var path: String {
        var p = "/api/realtime/client_secrets"
        if let lang = language {
            p += "?language=\(lang)"
        }
        return p
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
