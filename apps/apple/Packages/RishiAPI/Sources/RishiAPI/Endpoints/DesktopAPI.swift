import Foundation

// Desktop OAuth handoff parity (used by Phase 11 if we add a desktop bridge).
// Phase 3 ships SIWA + in-app Google OAuth via ASWebAuthenticationSession on
// iOS, so these endpoints are wired through for parity with electron rather
// than as the primary v1 iOS auth path.

// MARK: - POST /desktop/start

/// `POST /desktop/start` — begin a magic-link or Google OAuth flow.
public struct DesktopStartEndpoint: WorkerEndpointWithBody {
    public typealias Response = StartResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let codeChallenge: String
        public let mode: String
        public let email: String?

        enum CodingKeys: String, CodingKey {
            case codeChallenge = "code_challenge"
            case mode
            case email
        }

        public init(codeChallenge: String, mode: String, email: String? = nil) {
            self.codeChallenge = codeChallenge
            self.mode = mode
            self.email = email
        }
    }

    public struct StartResponse: Decodable, Sendable, Equatable {
        public let flowId: String
        public let webURL: String?

        enum CodingKeys: String, CodingKey {
            case flowId = "flow_id"
            case webURL = "web_url"
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/desktop/start"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - POST /desktop/poll

/// `POST /desktop/poll` — poll until the web flow completes (every 2s, 10min
/// timeout in the electron client).
public struct DesktopPollEndpoint: WorkerEndpointWithBody {
    public typealias Response = PollResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let flowId: String
        public let codeVerifier: String

        enum CodingKeys: String, CodingKey {
            case flowId       = "flow_id"
            case codeVerifier = "code_verifier"
        }

        public init(flowId: String, codeVerifier: String) {
            self.flowId = flowId
            self.codeVerifier = codeVerifier
        }
    }

    public struct PollResponse: Decodable, Sendable, Equatable {
        public let sessionToken: String?
        public let status: String

        enum CodingKeys: String, CodingKey {
            case sessionToken = "session_token"
            case status
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/desktop/poll"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - POST /desktop/cancel

/// `POST /desktop/cancel` — abort a pending desktop flow.
public struct DesktopCancelEndpoint: WorkerEndpointWithBody {
    public typealias Response = OkResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let flowId: String

        enum CodingKeys: String, CodingKey {
            case flowId = "flow_id"
        }

        public init(flowId: String) {
            self.flowId = flowId
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/desktop/cancel"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}
