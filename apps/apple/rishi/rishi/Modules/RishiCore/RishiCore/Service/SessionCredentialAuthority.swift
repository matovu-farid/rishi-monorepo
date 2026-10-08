import Foundation
import Synchronization

struct CredentialLease: Hashable, Sendable {
    let installationID: UUID
    let epoch: UInt64
    let rawUserID: String
}

struct CredentialAttemptTicket: Hashable, Sendable {
    fileprivate let id: UUID
}

struct CredentialRejectionContext: Equatable, Sendable {
    let lease: CredentialLease
    let tokenRevision: UInt64
    let ticket: CredentialAttemptTicket
}

enum CredentialRejectionCode: String, Sendable {
    case invalidRefreshToken = "INVALID_REFRESH_TOKEN"
    case refreshAccountUnavailable = "REFRESH_ACCOUNT_UNAVAILABLE"
    case identityMismatch = "IDENTITY_MISMATCH"
}

enum CredentialAuthenticationFailure: Error, Equatable, Sendable {
    case signedOut
    case unavailable(CredentialStorageFailure)
    case reauthenticationRequired
    case definitiveRejection(CredentialRejectionCode, CredentialRejectionContext)
    case accountChanged
}

struct CredentialSnapshot: Equatable, Sendable {
    let lease: CredentialLease
    let tokenRevision: UInt64
    let ticket: CredentialAttemptTicket
    let session: Session
    let refreshToken: String?

    var rejectionContext: CredentialRejectionContext {
        .init(lease: lease, tokenRevision: tokenRevision, ticket: ticket)
    }
}

struct CredentialTransition: Sendable {
    enum Outgoing: Sendable {
        case loaded(CredentialSnapshot)
        case absent
        case unavailable(CredentialStorageFailure)
    }
    let id: UUID
    let ticket: CredentialAttemptTicket
    let outgoing: Outgoing
}

enum CredentialRequestContext: Sendable {
    case normal(CredentialLease)
    case deletion(transactionID: UUID, outgoingLease: CredentialLease)
}

enum CredentialClearResult: Equatable, Sendable {
    case cleared
    case persistenceIncomplete(CredentialStorageFailure)
    case superseded
}

/// One item is either a complete session or an explicit signed-out tombstone.
struct CanonicalCredentialRecord: Codable, Sendable {
    let version: Int
    let installationID: UUID
    let tokenRevision: UInt64
    let session: Session?
    let refreshToken: String?
}

/// App-owned synchronous credential admission. Storage and compare/write share
/// one lock; transport, actor hops and account drains never run inside it.
final class SessionCredentialAuthority: Sendable {
    private enum Mode { case active, transitioning, cleared }
    private struct State {
        var loaded = false
        var record: CanonicalCredentialRecord?
        var epoch: UInt64 = 0
        var ticket = CredentialAttemptTicket(id: UUID())
        var mode = Mode.active
        var transition: CredentialTransition?
        var clearAttempted = false
    }
    private let persistence: any SessionCredentialPersistence
    private let clock: @Sendable () -> Date
    private let state = Mutex(State())

    init(persistence: any SessionCredentialPersistence = SecuritySessionCredentialPersistence(),
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.persistence = persistence
        self.clock = clock
    }

    func attemptTicket() -> CredentialAttemptTicket { state.withLock { $0.ticket } }

    func snapshot() throws -> CredentialSnapshot {
        try state.withLock { state in
            guard state.mode != .transitioning else { throw CredentialAuthenticationFailure.accountChanged }
            try load(&state)
            return try snapshot(in: state)
        }
    }

    func snapshot(for context: CredentialRequestContext) throws -> CredentialSnapshot {
        try state.withLock { state in
            switch context {
            case .normal(let lease):
                guard state.mode == .active else { throw CredentialAuthenticationFailure.accountChanged }
                try load(&state)
                let current = try snapshot(in: state)
                guard current.lease == lease else { throw CredentialAuthenticationFailure.accountChanged }
                return current
            case .deletion(let id, let lease):
                guard state.mode == .transitioning, !state.clearAttempted,
                      let transition = state.transition, transition.id == id,
                      case .loaded(let outgoing) = transition.outgoing,
                      outgoing.lease == lease else { throw CredentialAuthenticationFailure.accountChanged }
                return outgoing
            }
        }
    }

    /// Caller must first complete its synchronous local account preflight.
    func beginTransition(expected: CredentialAttemptTicket,
                         rejection: CredentialRejectionContext? = nil) throws -> CredentialTransition {
        try state.withLock { state in
            guard state.ticket == expected else { throw CredentialAuthenticationFailure.accountChanged }
            if let rejection {
                guard state.mode == .active,
                      let current = try? currentSnapshot(&state),
                      current.rejectionContext == rejection else { throw CredentialAuthenticationFailure.accountChanged }
            }
            let failure: CredentialStorageFailure?
            do { try load(&state); failure = nil }
            catch CredentialAuthenticationFailure.unavailable(let reason) { failure = reason }
            catch { failure = .invalidRecord }
            let incomplete = state.mode == .transitioning && state.clearAttempted
            state.epoch &+= 1
            state.ticket = CredentialAttemptTicket(id: UUID())
            let outgoing: CredentialTransition.Outgoing
            if incomplete { outgoing = .unavailable(.retirementIncomplete) }
            else if let failure { outgoing = .unavailable(failure) }
            else if let value = try? snapshot(in: state) { outgoing = .loaded(value) }
            else { outgoing = .absent }
            let transition = CredentialTransition(id: UUID(), ticket: state.ticket, outgoing: outgoing)
            state.mode = .transitioning
            state.transition = transition
            state.clearAttempted = false
            return transition
        }
    }

    func install(session: Session, refreshToken: String?,
                 in transition: CredentialTransition) throws -> CredentialSnapshot {
        try state.withLock { state in
            try requirePending(transition, state)
            guard !session.token.isEmpty, !session.userId.isEmpty else {
                throw CredentialAuthenticationFailure.unavailable(.invalidRecord)
            }
            let record = CanonicalCredentialRecord(version: 1, installationID: UUID(), tokenRevision: 0,
                                                   session: session, refreshToken: nonempty(refreshToken))
            try persist(record)
            activate(record, state: &state)
            return try snapshot(in: state)
        }
    }

    func commitRefresh(accessToken: String, refreshToken: String, issuedAt: Date,
                       expected: CredentialSnapshot) throws -> CredentialSnapshot {
        try state.withLock { state in
            guard state.mode == .active,
                  let current = try? currentSnapshot(&state),
                  current.rejectionContext == expected.rejectionContext else {
                throw CredentialAuthenticationFailure.accountChanged
            }
            guard current.refreshToken != nil else { throw CredentialAuthenticationFailure.reauthenticationRequired }
            guard !accessToken.isEmpty, !refreshToken.isEmpty else {
                throw CredentialAuthenticationFailure.unavailable(.invalidRecord)
            }
            let session = Session(token: accessToken, userId: current.session.userId,
                                  email: current.session.email, issuedAt: issuedAt, expiresAt: nil)
            let record = CanonicalCredentialRecord(version: 1, installationID: current.lease.installationID,
                                                   tokenRevision: current.tokenRevision &+ 1,
                                                   session: session, refreshToken: refreshToken)
            try persist(record)
            state.record = record
            return try snapshot(in: state)
        }
    }

    func restoreOutgoing(in transition: CredentialTransition) throws -> CredentialSnapshot {
        try state.withLock { state in
            try requirePending(transition, state)
            guard !state.clearAttempted, case .loaded(let outgoing) = transition.outgoing else {
                throw CredentialAuthenticationFailure.accountChanged
            }
            let record = CanonicalCredentialRecord(version: 1, installationID: UUID(),
                                                   tokenRevision: outgoing.tokenRevision, session: outgoing.session,
                                                   refreshToken: outgoing.refreshToken)
            try persist(record)
            activate(record, state: &state)
            return try snapshot(in: state)
        }
    }

    func clear(in transition: CredentialTransition) -> CredentialClearResult {
        state.withLock { state in
            guard state.transition?.id == transition.id else { return .superseded }
            if state.mode == .cleared { return .cleared }
            guard state.mode == .transitioning, state.ticket == transition.ticket else { return .superseded }
            state.clearAttempted = true
            let record = CanonicalCredentialRecord(version: 1, installationID: UUID(), tokenRevision: 0,
                                                   session: nil, refreshToken: nil)
            do { try persist(record) }
            catch CredentialAuthenticationFailure.unavailable(let reason) { return .persistenceIncomplete(reason) }
            catch { return .persistenceIncomplete(.invalidRecord) }
            state.record = record
            state.loaded = true
            state.epoch &+= 1
            state.ticket = CredentialAttemptTicket(id: UUID())
            state.mode = .cleared
            try? persistence.removeLegacy()
            return .cleared
        }
    }

    func isCurrent(_ lease: CredentialLease) -> Bool {
        state.withLock { state in state.mode == .active && (try? snapshot(in: state).lease) == lease }
    }

    /// Needed for signed-out/recovery UI: after clear there is no active lease.
    func isCurrent(_ transition: CredentialTransition) -> Bool {
        state.withLock { $0.transition?.id == transition.id }
    }

    /// Body remains on the caller's actor and must not re-enter this authority.
    func performIfCurrent(_ lease: CredentialLease, mutation: () -> Void) -> Bool {
        state.withLock { state in
            guard state.mode == .active, (try? snapshot(in: state).lease) == lease else { return false }
            mutation()
            return true
        }
    }

    func performIfCurrent(_ transition: CredentialTransition, mutation: () -> Void) -> Bool {
        state.withLock { state in
            guard state.transition?.id == transition.id else { return false }
            mutation()
            return true
        }
    }

    private func requirePending(_ transition: CredentialTransition, _ state: State) throws {
        guard state.mode == .transitioning, state.transition?.id == transition.id,
              state.ticket == transition.ticket else { throw CredentialAuthenticationFailure.accountChanged }
    }

    private func activate(_ record: CanonicalCredentialRecord, state: inout State) {
        state.record = record
        state.loaded = true
        state.ticket = CredentialAttemptTicket(id: UUID())
        state.mode = .active
        state.transition = nil
        state.clearAttempted = false
    }

    private func currentSnapshot(_ state: inout State) throws -> CredentialSnapshot {
        try load(&state)
        return try snapshot(in: state)
    }

    private func snapshot(in state: State) throws -> CredentialSnapshot {
        guard let record = state.record, let session = record.session else {
            throw CredentialAuthenticationFailure.signedOut
        }
        return CredentialSnapshot(lease: .init(installationID: record.installationID, epoch: state.epoch,
                                               rawUserID: session.userId), tokenRevision: record.tokenRevision,
                                  ticket: state.ticket, session: session, refreshToken: record.refreshToken)
    }

    private func load(_ state: inout State) throws {
        guard !state.loaded else { return }
        do {
            if let data = try persistence.readCanonical() {
                if let record = try? JSONDecoder().decode(CanonicalCredentialRecord.self, from: data) {
                    guard record.version == 1 else { throw CredentialStorageFailure.unsupportedVersion }
                    guard record.session.map({ !$0.token.isEmpty && !$0.userId.isEmpty }) ?? (record.refreshToken == nil),
                          record.refreshToken.map({ !$0.isEmpty }) ?? true else { throw CredentialStorageFailure.invalidRecord }
                    state.record = record
                } else {
                    // A malformed envelope is never interpreted as an old Session.
                    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["version"] != nil {
                        throw CredentialStorageFailure.invalidRecord
                    }
                    guard let session = try? JSONDecoder().decode(Session.self, from: data) else {
                        throw CredentialStorageFailure.invalidRecord
                    }
                    state.record = try migrate(session: session, legacy: persistence.readLegacy())
                }
            } else {
                let legacy = try persistence.readLegacy()
                if legacy.accessToken == nil, legacy.userID == nil, legacy.refreshToken == nil { state.record = nil }
                else {
                    guard let token = nonempty(legacy.accessToken), let owner = nonempty(legacy.userID) else {
                        throw CredentialStorageFailure.inconsistentLegacy
                    }
                    state.record = try migrate(session: Session(token: token, userId: owner, email: nil, issuedAt: clock()), legacy: legacy)
                }
            }
            state.loaded = true
        } catch let reason as CredentialStorageFailure {
            throw CredentialAuthenticationFailure.unavailable(reason)
        } catch let reason as CredentialAuthenticationFailure { throw reason }
        catch { throw CredentialAuthenticationFailure.unavailable(.invalidRecord) }
    }

    private func migrate(session: Session, legacy: LegacyCredentials) throws -> CanonicalCredentialRecord {
        guard !session.token.isEmpty, !session.userId.isEmpty,
              legacy.userID.map({ $0 == session.userId }) ?? true,
              legacy.accessToken.map({ $0 == session.token }) ?? true else {
            throw CredentialStorageFailure.inconsistentLegacy
        }
        let matchingPair = legacy.userID == session.userId && legacy.accessToken == session.token
        // Unverified decoding is only a consistency filter; server validates JWTs.
        let refresh = matchingPair && jwtOwner(session.token) == session.userId && jwtOwner(legacy.refreshToken) == session.userId
            ? nonempty(legacy.refreshToken) : nil
        let record = CanonicalCredentialRecord(version: 1, installationID: UUID(), tokenRevision: 0,
                                               session: session, refreshToken: refresh)
        try persist(record)
        try? persistence.removeLegacy()
        return record
    }

    private func persist(_ record: CanonicalCredentialRecord) throws {
        do { try persistence.writeCanonical(JSONEncoder().encode(record)) }
        catch let reason as CredentialStorageFailure { throw CredentialAuthenticationFailure.unavailable(reason) }
        catch { throw CredentialAuthenticationFailure.unavailable(.invalidEncoding) }
    }

    private func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }

    private func jwtOwner(_ token: String?) -> String? {
        guard let token else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["userId"] as? String
    }
}
