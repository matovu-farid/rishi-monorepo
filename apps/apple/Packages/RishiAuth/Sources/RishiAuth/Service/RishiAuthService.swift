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
    /// ``Self.deriveUserUUID(from:)`` — the same input String always yields the
    /// same UUID, so in-memory User.id is stable across sign-ins. The
    /// Phase-14 `apple_subscriptions.userId` join is unaffected because that
    /// join keys against the worker-side String (read from Session.userId
    /// directly by network calls), not the derived in-memory UUID.
    private func makeUser(from session: Session) -> User {
        let derivedId = Self.deriveUserUUID(from: session.userId)
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

    /// Derives a stable UUID from an arbitrary identifier String.
    ///
    /// If `id` already parses as a UUID (legacy Phase-3 keychain blobs
    /// where the userId was a real UUID string), return that UUID verbatim
    /// so existing on-device sessions keep the same in-memory User.id
    /// across the migration.
    ///
    /// Otherwise compute a name-based UUID by hashing the input with a
    /// fixed namespace and packing the first 16 bytes into a UUID with
    /// RFC 4122 version 5 / variant bits set. Same input always yields the
    /// same UUID.
    static func deriveUserUUID(from id: String) -> UUID {
        if let direct = UUID(uuidString: id) {
            return direct
        }
        // Fixed namespace bytes for Rishi-Apple-derived user IDs. Random
        // 16-byte literal chosen once; do not change without a migration
        // plan (would shuffle every Apple user's derived UUID).
        var bytes: [UInt8] = [
            0x52, 0x49, 0x53, 0x48, 0x49, 0x41, 0x55, 0x54,
            0x48, 0x55, 0x53, 0x45, 0x52, 0x49, 0x44, 0x73,
        ]
        for byte in id.utf8 {
            // FNV-1a-ish 8-bit mix into a 16-byte rolling state.
            let idx = Int(byte) % 16
            bytes[idx] = bytes[idx] &+ byte
            bytes[idx] ^= UInt8((Int(bytes[idx]) &* 31 + Int(byte)) & 0xFF)
        }
        // Stir again with the full string length so short inputs don't
        // collapse onto each other.
        let len = UInt32(id.utf8.count)
        bytes[0] ^= UInt8(len & 0xFF)
        bytes[1] ^= UInt8((len >> 8) & 0xFF)
        bytes[2] ^= UInt8((len >> 16) & 0xFF)
        bytes[3] ^= UInt8((len >> 24) & 0xFF)
        // Set version (5) and variant (RFC 4122) per UUIDv5 layout.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
