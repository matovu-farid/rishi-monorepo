import Foundation
import RishiCore
import RishiLogging
import RishiAPI

/// Top-level RishiAuth surface — conforms to ``RishiCore.AuthService`` and
/// aggregates the SIWA coordinator with the keychain store and worker
/// client. Plan 03-06 constructs one of these in the app's composition root.
///
/// Tests inject mocks via the protocol-typed initializer
/// (``AppleSignInDriver`` from ``SignInDriver.swift``); production code uses
/// the convenience initializer that takes the concrete coordinator actor.
///
/// Phase 15 plan 15-03: Google Sign-In was hard-removed; SIWA is the sole
/// social provider for v1. The worker still performs Apple's `/auth/revoke`
/// server-side per `WORKER-TICKETS.md` Ticket 1 inside `deleteAccount()`.
public actor RishiAuthService: AuthService {

    private let siwaDriver: any AppleSignInDriver
    private let keychain: KeychainSessionStore
    private let workerClient: WorkerClient

    /// Driver-protocol initializer for testability. Inject ``MockAppleDriver``
    /// (defined inline by ``RishiAuthServiceTests``) here.
    public init(
        siwaDriver: any AppleSignInDriver,
        keychain: KeychainSessionStore,
        workerClient: WorkerClient
    ) {
        self.siwaDriver = siwaDriver
        self.keychain = keychain
        self.workerClient = workerClient
    }

    /// Convenience initializer for app composition. Forwards into the
    /// driver-protocol init — the concrete coordinator conforms to the driver
    /// protocol via the retroactive extension in ``SignInDriver.swift``.
    public init(
        workerClient: WorkerClient,
        siwaCoordinator: SignInWithAppleCoordinator,
        keychain: KeychainSessionStore
    ) {
        self.siwaDriver = siwaCoordinator
        self.keychain = keychain
        self.workerClient = workerClient
    }

    // MARK: - AuthService conformance

    public var currentUser: User? {
        get async {
            do {
                guard let session = try await keychain.load() else { return nil }
                return makeUser(from: session)
            } catch {
                Log.error("auth.current_user.load_failed", error: error)
                return nil
            }
        }
    }

    public func signInWithApple() async throws -> User {
        let session = try await siwaDriver.signIn()
        try await keychain.save(session)
        Log.event("auth.signed_in", level: .info, data: ["provider": "apple"])
        return makeUser(from: session)
    }

    /// Best-effort `POST /api/auth/sign-out` followed by an unconditional
    /// keychain clear. If the worker rejects the request (e.g. token already
    /// invalidated server-side), the local session is still cleared — better
    /// to log the user out locally than to leave them in a broken half-state.
    public func signOut() async throws {
        do {
            _ = try await workerClient.send(SignOutEndpoint())
        } catch {
            Log.error("auth.signout.worker_failed", error: error)
        }
        try await keychain.delete()
        Log.event("auth.signed_out", level: .info)
    }

    /// `POST /api/auth/delete-user`. On success the keychain is cleared. On
    /// failure the error is re-thrown WITHOUT clearing the keychain — the
    /// account still exists server-side so the user can retry from the same
    /// signed-in state. Worker performs Apple `/auth/revoke` internally per
    /// `WORKER-TICKETS.md` Ticket 1.
    public func deleteAccount() async throws {
        _ = try await workerClient.send(DeleteUserEndpoint())
        try await keychain.delete()
        Log.event("auth.account_deleted", level: .info)
    }

    // MARK: - Helpers

    /// Synthesises a ``RishiCore.User`` from a persisted ``Session``.
    ///
    /// `Session.email` is Optional (private-relay or 2nd-sign-in cases —
    /// PITFALLS.md Pitfall 10) but `User.email` is non-optional in the domain
    /// model. We synthesise a placeholder address of the form
    /// `apple+<userId>.local` so the domain model can be constructed; **UI
    /// code that needs the displayable address MUST read `session.email`
    /// directly** (Settings does this), never `user.email`.
    ///
    /// Plan 15-02: `Session.userId` is now `String` (Apple `sub` /
    /// Better Auth `user.id`). `User.id` remains `UserID = UUID` because the
    /// rest of the app graph (BookStore, PositionStore, LibraryViewModel,
    /// SyncEngine) keys every owner FK off a UUID. We derive a stable v5-ish
    /// namespace UUID from the Session userId String via
    /// ``DerivedUserID/from(_:)`` — the same input String always yields the
    /// same UUID, so in-memory User.id is stable across sign-ins. The
    /// Phase-14 `apple_subscriptions.userId` join is unaffected because that
    /// join keys against the worker-side String (read from Session.userId
    /// directly by network calls), not the derived in-memory UUID.
    private func makeUser(from session: Session) -> User {
        let derivedId = DerivedUserID.from(session.userId)
        let email = session.email
            ?? "\(session.provider.rawValue)+\(session.userId).local"
        return User(
            id: derivedId,
            email: email,
            displayName: nil,
            avatarURL: nil,
            hasPro: false,
            createdAt: session.issuedAt
        )
    }
}
