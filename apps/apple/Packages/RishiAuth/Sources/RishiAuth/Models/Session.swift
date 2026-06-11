import Foundation
import RishiCore

/// A persisted authentication session.
///
/// Stored as a single JSON-encoded keychain item by ``KeychainSessionStore``
/// (plan 03-02). The `token` field is the Bearer token forwarded by
/// ``RishiAuthTokenProvider`` (plan 03-05) to `WorkerClient` on every request.
///
/// `userId` is the Better Auth `user.id` String — for Apple sign-in, this is
/// Apple's `sub` claim verbatim (e.g. `001234.abcdef0123456789.1234`) and is
/// NEVER UUID-shaped. Plan 15-02 changed this from `UserID` (UUID) to `String`
/// to match the production wire format (Phase 14's `apple_subscriptions`
/// table joins against Better Auth `user.id`, a String). Legacy on-disk
/// Keychain blobs that contain a UUID-shaped string in `userId` decode
/// transparently — JSON-level representation is identical.
///
/// `email` is Optional because Sign-in-with-Apple may return nil OR a
/// `@privaterelay.appleid.com` address per PITFALLS.md Pitfall 10 — never
/// assume a real address can be recovered from this field.
///
/// `expiresAt` is Optional because the Phase 3 worker contract does not
/// guarantee an explicit expiry; if nil, the client treats the session as
/// valid until a 401 forces re-sign-in.
public struct Session: Codable, Sendable, Equatable, Hashable {
    public let token: String
    public let userId: String
    public let email: String?
    public let provider: SignInProvider
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(
        token: String,
        userId: String,
        email: String?,
        provider: SignInProvider,
        issuedAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        self.token = token
        self.userId = userId
        self.email = email
        self.provider = provider
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }
}
