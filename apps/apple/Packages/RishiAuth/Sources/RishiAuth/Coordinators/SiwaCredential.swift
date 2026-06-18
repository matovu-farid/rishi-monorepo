import Foundation

// MARK: - Scope mirror

/// Scope mirror so callers never have to import AuthenticationServices.
/// The production ``SystemSiwaPresenter`` translates these into
/// `[ASAuthorization.Scope]` at request time.
public enum SiwaScope: Hashable, Sendable {
    case fullName
    case email
}

// MARK: - Structured name mirror

/// Plan 15-06: Better Auth's `/api/auth/sign-in/social` Apple `idToken.user.name`
/// is a structured `{firstName, lastName}` object — see
/// `@better-auth/core/social-providers/apple.mjs:77` which concatenates
/// `${token.user.name.firstName} ${token.user.name.lastName}` for the user row.
/// We capture `PersonNameComponents.givenName` and `.familyName` as discrete
/// fields rather than collapsing them through `PersonNameComponentsFormatter`,
/// which would lose the structure Better Auth needs.
public struct SiwaName: Sendable, Equatable, Hashable {
    public let firstName: String?
    public let lastName: String?

    public init(firstName: String?, lastName: String?) {
        self.firstName = firstName
        self.lastName = lastName
    }
}

// MARK: - Credential mirror

/// Sendable mirror of the fields ``SignInWithAppleCoordinator`` needs from
/// `ASAuthorizationAppleIDCredential`.
///
/// Plan 15-06 shape:
/// - `identityTokenData`: raw bytes from `ASAuthorizationAppleIDCredential.identityToken`.
///   These bytes ARE the UTF-8 of the JWT string — the coordinator decodes via
///   `String(data:encoding:.utf8)` and forwards the raw JWT. NO base64 re-wrap
///   (PITFALLS Pitfall 2 — Better Auth's `decodeJwt` expects a raw JWT string).
/// - `fullName`: structured `{firstName, lastName}` instead of a collapsed
///   display string. Only present on the very first authorization
///   (PITFALLS Pitfall 8).
/// - `nonceHex`: SHA-256 hex digest the presenter bound into
///   `ASAuthorizationAppleIDRequest.nonce`. The coordinator posts the SAME hex
///   as `idToken.nonce` to Better Auth — string-equality check at
///   `apple.mjs:58` (PITFALLS Pitfall 1).
public struct SiwaCredential: Sendable, Equatable {
    public let identityTokenData: Data
    public let authorizationCode: Data
    /// Apple's stable `sub` (`user` field) — primary key for the worker.
    public let user: String
    /// Structured name; `nil` on every sign-in after the first
    /// (PITFALLS Pitfall 8/10).
    public let fullName: SiwaName?
    /// `nil` OR a `@privaterelay.appleid.com` address — both pass through
    /// unchanged to the worker (PITFALLS Pitfall 10). `nil` on every
    /// sign-in after the first.
    public let email: String?
    /// SHA-256 hex digest of the per-request raw nonce. The presenter bound
    /// the SAME string into `ASAuthorizationAppleIDRequest.nonce` so the JWT
    /// returned by Apple carries it verbatim in the `nonce` claim. The
    /// coordinator forwards this same hex to Better Auth as `idToken.nonce`.
    public let nonceHex: String

    public init(
        identityTokenData: Data,
        authorizationCode: Data,
        user: String,
        fullName: SiwaName?,
        email: String?,
        nonceHex: String
    ) {
        self.identityTokenData = identityTokenData
        self.authorizationCode = authorizationCode
        self.user = user
        self.fullName = fullName
        self.email = email
        self.nonceHex = nonceHex
    }
}

// MARK: - Presenter seam

/// Seam between ``SignInWithAppleCoordinator`` and AuthenticationServices.
/// Tests inject a mock presenter that yields a canned credential or throws
/// cancellation; production uses ``SystemSiwaPresenter``.
public protocol SiwaPresenter: Sendable {
    func presentSignInRequest(scopes: Set<SiwaScope>) async throws -> SiwaCredential
}
