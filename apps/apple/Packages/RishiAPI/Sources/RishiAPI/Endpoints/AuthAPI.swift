import Foundation

// MARK: - Shared shapes

/// A signed-in user as projected by `/api/auth/get-session`.
///
/// Snake-case wire keys are mapped via ``CodingKeys`` so the rest of the app
/// can talk in idiomatic Swift camelCase.
public struct SessionUser: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let email: String
    public let displayName: String?
    public let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case avatarURL   = "avatar_url"
    }

    public init(
        id: String,
        email: String,
        displayName: String? = nil,
        avatarURL: String? = nil
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// Response envelope returned by `/api/auth/google` and `/api/auth/apple`.
public struct AuthSessionResponse: Decodable, Sendable, Equatable, Hashable {
    public let sessionToken: String
    public let userId: String
    public let email: String?

    enum CodingKeys: String, CodingKey {
        case sessionToken = "session_token"
        case userId       = "user_id"
        case email
    }
}

/// `{"ok": true}` envelope returned by mutation endpoints that don't have a
/// payload of their own (sign-out, delete-user, desktop/cancel, …).
public struct OkResponse: Decodable, Sendable, Equatable, Hashable {
    public let ok: Bool
}

// MARK: - Google sign-in

/// `POST /api/auth/google` — exchange a Google ID token for a Rishi session.
public struct GoogleSignInEndpoint: WorkerEndpointWithBody {
    public typealias Response = AuthSessionResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let idToken: String

        enum CodingKeys: String, CodingKey {
            case idToken = "id_token"
        }

        public init(idToken: String) {
            self.idToken = idToken
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/auth/google"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - Sign in with Apple
//
// Cross-team blocker per STATE.md: the worker SIWA token-verification endpoint
// is still pending. The Swift type is declared now so Phase 3 plans can compile
// against the contract immediately once the worker ships.
//
// TODO(worker): wait for `/api/auth/apple` to be deployed before Phase 3 wires
// this endpoint into the live sign-in flow.

/// `POST /api/auth/apple` — exchange a Sign-in-with-Apple identity token for a
/// Rishi session.
///
/// Per STATE.md Phase 0 SIWA pitfalls, the primary key on the server is Apple's
/// stable `user_identifier` (the `user` field below) — `email` may be missing
/// entirely or carry an `@privaterelay.appleid.com` address that rotates on
/// re-sign-in. `fullName` is only emitted by Apple on the FIRST authorization.
public struct AppleSignInEndpoint: WorkerEndpointWithBody {
    public typealias Response = AuthSessionResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let identityToken: String
        public let authorizationCode: String
        /// Apple's stable user identifier (`sub`). MUST be persisted as the
        /// primary key on the server — email is unreliable.
        public let user: String?
        /// JSON-encoded `PersonNameComponents`. Only present on the very first
        /// authorization; absent on subsequent sign-ins.
        public let fullName: String?
        /// Empty / `@privaterelay.appleid.com` is normal — do not fail on it.
        public let email: String?

        enum CodingKeys: String, CodingKey {
            case identityToken     = "identity_token"
            case authorizationCode = "authorization_code"
            case user
            case fullName          = "full_name"
            case email
        }

        public init(
            identityToken: String,
            authorizationCode: String,
            user: String? = nil,
            fullName: String? = nil,
            email: String? = nil
        ) {
            self.identityToken = identityToken
            self.authorizationCode = authorizationCode
            self.user = user
            self.fullName = fullName
            self.email = email
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/auth/apple"
    public let body: Body

    public init(body: Body) {
        self.body = body
    }
}

// MARK: - Sign-out (Bearer-auth)

/// `POST /api/auth/sign-out` — Better Auth sign-out.
public struct SignOutEndpoint: WorkerEndpoint {
    public typealias Response = OkResponse

    public let method: HTTPMethod = .POST
    public let path: String = "/api/auth/sign-out"

    public init() {}
}

// MARK: - Delete user (Bearer-auth)

/// `POST /api/auth/delete-user` — full account deletion.
///
/// Server-side MUST call `https://appleid.apple.com/auth/revoke` before row
/// deletion per STATE.md Phase 0 decision (App Store Guideline 5.1.1(v)). The
/// client doesn't need to know about that — it just hits this endpoint and
/// trusts the worker to do the right thing.
public struct DeleteUserEndpoint: WorkerEndpoint {
    public typealias Response = OkResponse

    public let method: HTTPMethod = .POST
    public let path: String = "/api/auth/delete-user"

    public init() {}
}

// MARK: - Get session (hydrate)

/// `GET /api/auth/get-session` — re-hydrate the local session from a stored
/// bearer token at app start.
public struct GetSessionEndpoint: WorkerEndpoint {
    public typealias Response = ProfileResponse

    public let method: HTTPMethod = .GET
    public let path: String = "/api/auth/get-session"

    public init() {}

    public struct ProfileResponse: Decodable, Sendable, Equatable {
        public let user: SessionUser
        public let hasPro: Bool

        enum CodingKeys: String, CodingKey {
            case user
            case hasPro = "has_pro"
        }
    }
}
