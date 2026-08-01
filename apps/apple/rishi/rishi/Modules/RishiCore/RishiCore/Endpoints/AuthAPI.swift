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

/// `{"ok": true}` envelope returned by mutation endpoints that don't have a
/// payload of their own (sign-out, delete-user, desktop/cancel, …).
public struct OkResponse: Decodable, Sendable, Equatable, Hashable {
    public let ok: Bool
}

// MARK: - Sign in with Apple (Better Auth social provider)

/// `POST /api/auth/sign-in/social` — exchange a Sign-in-with-Apple identity
/// token for a Rishi session via Better Auth's first-party Apple provider.
///
/// Wire contract verified against the installed `@better-auth/core@1.6.10`
/// source (`social-providers/apple.mjs` + `api/routes/sign-in.mjs`). The
/// `idToken` field is an OBJECT (not a top-level string): `token` is the raw
/// JWT from `ASAuthorizationAppleIDCredential.identityToken` (UTF-8 decoded —
/// NOT base64 re-encoded), `nonce` is the SHA-256 hex digest of the raw nonce
/// the iOS client sent to Apple (Better Auth compares string-equality against
/// the `nonce` claim on the JWT — `apple.mjs:58`), and `user` carries Apple's
/// disclosed full name + email on the very first authorization only.
///
/// Response uses Better Auth's standard envelope: `redirect` is `false` for
/// native idToken sign-in, `token` is the bearer token (also set as the
/// `rishi.session_token` cookie), and `user.id` is the Apple `sub` (a string
/// like `001234.abcdef.5678`, NOT a UUID).
public struct SignInSocialEndpoint: WorkerEndpointWithBody {
    public typealias Response = SignInSocialResponse

    public struct Body: Encodable, Sendable, Equatable {
        public let provider: String
        public let idToken: IdToken
        public let disableRedirect: Bool

        public struct IdToken: Encodable, Sendable, Equatable {
            public let token: String
            public let nonce: String
            public let user: AppleUser?

            public struct AppleUser: Encodable, Sendable, Equatable {
                public let name: AppleName?
                public let email: String?

                public struct AppleName: Encodable, Sendable, Equatable {
                    public let firstName: String?
                    public let lastName: String?

                    public init(firstName: String?, lastName: String?) {
                        self.firstName = firstName
                        self.lastName = lastName
                    }
                }

                public init(name: AppleName?, email: String?) {
                    self.name = name
                    self.email = email
                }
            }

            public init(token: String, nonce: String, user: AppleUser?) {
                self.token = token
                self.nonce = nonce
                self.user = user
            }
        }

        public init(provider: String, idToken: IdToken, disableRedirect: Bool) {
            self.provider = provider
            self.idToken = idToken
            self.disableRedirect = disableRedirect
        }
    }

    public struct SignInSocialResponse: Decodable, Sendable, Equatable {
        public let redirect: Bool
        public let token: String
        public let user: User

        public struct User: Decodable, Sendable, Equatable {
            public let id: String
            public let email: String?
            public let name: String?
            public let emailVerified: Bool?
            public let image: String?
        }
    }

    public let method: HTTPMethod = .POST
    public let path: String = "/api/auth/sign-in/social"
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

/// `DELETE /api/user` — full account deletion for the authenticated user.
///
/// The client sends no account data; the authenticated worker identifies the
/// user from the bearer token and performs the deletion.
public struct DeleteUserEndpoint: WorkerEndpoint {
    public typealias Response = OkResponse

    public let method: HTTPMethod = .DELETE
    public let path: String = "/api/user"

    public init() {}
}

// MARK: - Get session (hydrate)

/// `GET /api/auth/get-session` — re-hydrate the local session from a stored
/// bearer token at app start.
///
/// Better Auth returns literal JSON `null` (not 401, not an empty object) when
/// the request has no active session. `Response` is therefore Optional so
/// `JSONDecoder` produces `nil` for the unauthenticated case rather than
/// throwing `valueNotFound`. Consumers must treat `nil` as "no session, user
/// is free-tier" — see `RishiBilling.EntitlementService.refresh()`.
public struct GetSessionEndpoint: WorkerEndpoint {
    public typealias Response = ProfileResponse?

    public let method: HTTPMethod = .GET
    public let path: String = "/api/auth/get-session"

    public init() {}

    public struct ProfileResponse: Decodable, Sendable, Equatable {
        public let user: SessionUser
        /// `false` when the worker payload omits `has_pro` entirely.
        /// The worker side of `/api/auth/get-session` does not always
        /// emit `has_pro` (it's set only when the entitlement projection
        /// runs server-side), so the client treats absence as the
        /// safer "free tier" default rather than failing the whole
        /// decode and breaking session hydration.
        public let hasPro: Bool

        enum CodingKeys: String, CodingKey {
            case user
            case hasPro = "has_pro"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.user = try container.decode(SessionUser.self, forKey: .user)
            self.hasPro = try container.decodeIfPresent(Bool.self, forKey: .hasPro) ?? false
        }

        public init(user: SessionUser, hasPro: Bool) {
            self.user = user
            self.hasPro = hasPro
        }
    }
}
