import Foundation
import Security
import RishiLogging

/// Persists a single ``Session`` JSON blob in the Keychain under
/// `service=org.fidexa.rishi.session, account=current`.
///
/// Actor isolation serialises concurrent save/load/delete calls without locks.
/// The dependency on ``KeychainBackend`` makes the whole surface unit-testable
/// via ``InMemoryKeychainBackend`` without touching the real keychain.
public actor KeychainSessionStore {

    /// Constants used by every query so service/account never drift between operations.
    public static let service = "org.fidexa.rishi.session"
    public static let account = "current"

    private let backend: any KeychainBackend
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(backend: any KeychainBackend = SystemKeychainBackend()) {
        self.backend = backend
        // Session's Codable uses default Date encoding (Double timestamp). Default encoders are fine.
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    public func save(_ session: Session) async throws {
        let data: Data
        do {
            data = try encoder.encode(session)
        } catch {
            throw KeychainError.codec("encode Session: \(error)")
        }

        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        do {
            try await backend.add(query: query)
            Log.event("auth.session.saved", level: .info)
        } catch KeychainError.unexpectedStatus(let status) where status == errSecDuplicateItem {
            // Item exists — update its data in place under the same (service, account).
            try await backend.update(
                query: baseQuery(),
                attributes: [kSecValueData as String: data]
            )
            Log.event("auth.session.updated", level: .info)
        }
    }

    public func load() async throws -> Session? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        guard let data = try await backend.copyMatching(query: query) else {
            return nil
        }
        do {
            return try decoder.decode(Session.self, from: data)
        } catch {
            throw KeychainError.codec("decode Session: \(error)")
        }
    }

    public func delete() async throws {
        try await backend.delete(query: baseQuery())
        Log.event("auth.session.cleared", level: .info)
    }

    // MARK: - Helpers

    /// `nonisolated` so the resulting dictionary is not in the actor's isolation
    /// region — required to pass it to a `sending` parameter on the backend
    /// without Swift 6 flagging a data-race risk. Marked `sending` to make the
    /// transfer guarantee explicit at the call site.
    private nonisolated func baseQuery() -> sending [String: Any] {
        return [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }
}
