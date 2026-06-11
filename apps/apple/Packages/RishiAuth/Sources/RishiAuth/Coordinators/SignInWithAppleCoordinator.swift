import Foundation
import RishiCore
import RishiLogging
import RishiAPI

/// Drives the Sign-in-with-Apple flow:
///   1. Ask ``SiwaPresenter`` to present `ASAuthorizationController` (the
///      presenter generates a per-request nonce via ``Nonce`` and binds the
///      SHA-256 hex digest into `ASAuthorizationAppleIDRequest.nonce` BEFORE
///      calling `performRequests()`).
///   2. POST the resulting credential to Better Auth's standard
///      `POST /api/auth/sign-in/social` endpoint via ``WorkerClient`` using
///      ``RishiAPI/SignInSocialEndpoint``.
///   3. Project the worker response into a ``Session`` for Keychain storage.
///
/// Aggregated into the top-level ``RishiAuthService`` (plan 03-05) which also
/// performs the Keychain write — this actor does NOT touch Keychain itself.
///
/// Plan 15-06 rewrite:
/// - Switched from the legacy custom `/api/auth/apple` to Better Auth's
///   standard `/api/auth/sign-in/social` (verified against
///   `@better-auth/core@1.6.10` source).
/// - `idToken.token` is the RAW JWT string decoded from the credential's
///   identity-token bytes — NOT base64-re-wrapped (PITFALLS Pitfall 2).
/// - `idToken.nonce` is the SAME SHA-256 hex digest the presenter bound to
///   the Apple request (PITFALLS Pitfall 1).
/// - `idToken.user` is OMITTED on second-and-later sign-ins where Apple
///   discloses neither fullName nor email (PITFALLS Pitfall 8) — sending an
///   empty-string user block would clobber the user.name Better Auth already
///   has.
/// - `Session.userId` receives `response.user.id` directly as a String — no
///   UUID conversion (per plan 15-02; Apple `sub` is never UUID-shaped).
public actor SignInWithAppleCoordinator {

    private let workerClient: WorkerClient
    private let presenter: any SiwaPresenter

    public init(workerClient: WorkerClient, presenter: any SiwaPresenter) {
        self.workerClient = workerClient
        self.presenter = presenter
    }

    public func signIn() async throws -> Session {
        Log.event("auth.siwa.started", level: .info)
        let credential: SiwaCredential
        do {
            credential = try await presenter.presentSignInRequest(scopes: [.fullName, .email])
        } catch let error as RishiError {
            if case .cancelled = error {
                Log.event("auth.siwa.cancelled", level: .info)
            }
            throw error
        }

        // PITFALLS Pitfall 2: identityTokenData is the UTF-8 of the JWT
        // string. Decode straight through — Better Auth's `decodeJwt`
        // (apple.mjs:74) expects a raw JWT, not a base64 envelope.
        let tokenString = String(data: credential.identityTokenData, encoding: .utf8) ?? ""

        // PITFALLS Pitfall 8: on second-and-later sign-ins both fullName and
        // email are nil — omit `idToken.user` entirely so Better Auth doesn't
        // overwrite the user row with empty strings.
        let userPayload: SignInSocialEndpoint.Body.IdToken.AppleUser? = {
            guard credential.fullName != nil || credential.email != nil else {
                return nil
            }
            let appleName = credential.fullName.map {
                SignInSocialEndpoint.Body.IdToken.AppleUser.AppleName(
                    firstName: $0.firstName,
                    lastName: $0.lastName
                )
            }
            return SignInSocialEndpoint.Body.IdToken.AppleUser(
                name: appleName,
                email: credential.email
            )
        }()

        let body = SignInSocialEndpoint.Body(
            provider: "apple",
            idToken: SignInSocialEndpoint.Body.IdToken(
                token: tokenString,
                // PITFALLS Pitfall 1: the SAME hex digest the presenter
                // bound to Apple's request. Better Auth compares
                // jwtClaims.nonce === body.nonce (apple.mjs:58).
                nonce: credential.nonceHex,
                user: userPayload
            ),
            disableRedirect: true
        )
        let response = try await workerClient.send(SignInSocialEndpoint(body: body))

        // Plan 15-02 cascade: Session.userId is String. Apple's `sub`
        // (e.g. "001234.abcdef.5678") flows through verbatim from
        // response.user.id — no UUID conversion.
        let session = Session(
            token: response.token,
            userId: response.user.id,
            email: response.user.email,
            provider: .apple,
            issuedAt: Date(),
            expiresAt: nil
        )
        Log.event("auth.siwa.completed", level: .info)
        return session
    }
}
