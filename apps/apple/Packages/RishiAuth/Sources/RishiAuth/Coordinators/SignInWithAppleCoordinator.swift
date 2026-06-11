import Foundation
import RishiCore
import RishiLogging
import RishiAPI

/// Drives the Sign-in-with-Apple flow:
///   1. Ask ``SiwaPresenter`` to present `ASAuthorizationController`
///   2. POST the resulting credential to `/api/auth/apple` via ``WorkerClient``
///   3. Project the worker response into a ``Session`` for Keychain storage
///
/// Aggregated into the top-level ``RishiAuthService`` (plan 03-05) which also
/// performs the Keychain write — this actor does NOT touch Keychain itself.
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

        let body = AppleSignInEndpoint.Body(
            identityToken: credential.identityToken.base64EncodedString(),
            authorizationCode: credential.authorizationCode.base64EncodedString(),
            user: credential.user,
            fullName: credential.fullName,
            email: credential.email
        )
        let response = try await workerClient.send(AppleSignInEndpoint(body: body))

        // Worker is the source of truth for the email field — preserves any
        // @privaterelay.appleid.com address per PITFALLS.md Pitfall 10.
        // Plan 15-02: response.userId is the Better Auth `user.id` String
        // (Apple `sub` claim verbatim, never UUID-shaped). Forwarded into
        // Session.userId directly — no UUID conversion.
        let session = Session(
            token: response.sessionToken,
            userId: response.userId,
            email: response.email,
            provider: .apple,
            issuedAt: Date(),
            expiresAt: nil
        )
        Log.event("auth.siwa.completed", level: .info)
        return session
    }
}
