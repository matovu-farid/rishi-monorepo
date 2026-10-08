import Foundation

struct AccountDeletionAdmission: Sendable {
    let transactionID: UUID
    let outgoingLease: CredentialLease

    var requestContext: CredentialRequestContext {
        .deletion(transactionID: transactionID, outgoingLease: outgoingLease)
    }
}

/// Synchronous account-transition fence. Callers obtain this before creating
/// their own asynchronous cleanup task; the drain itself starts only after
/// the identity and generation fence has been committed.
@MainActor
final class AccountChangeTransaction {
    let expectedAccountGeneration: UInt64
    let drain: Task<Void, Never>
    let outgoingAccountID: UUID?
    let capturedLocalAccountID: UUID?
    /// Exact lease before the transition fence, for outgoing local projections.
    /// Deletion admission instead retains transition.outgoing's fenced lease.
    let outgoingNormalCredentialLease: CredentialLease?
    let outgoingAccountGeneration: UInt64?
    let activationToken: BookImportActivationToken?
    let outgoingAccountMutationPermit: AccountMutationPermit?
    let credentialTransition: CredentialTransition?

    var deletionAdmission: AccountDeletionAdmission? {
        guard let transition = credentialTransition,
              case .loaded(let outgoing) = transition.outgoing else { return nil }
        return AccountDeletionAdmission(transactionID: transition.id, outgoingLease: outgoing.lease)
    }

    init(expectedAccountGeneration: UInt64, outgoingAccountID: UUID? = nil, capturedLocalAccountID: UUID? = nil, outgoingNormalCredentialLease: CredentialLease? = nil, outgoingAccountGeneration: UInt64? = nil, activationToken: BookImportActivationToken? = nil, outgoingAccountMutationPermit: AccountMutationPermit? = nil, credentialTransition: CredentialTransition? = nil, drain: Task<Void, Never>) {
        self.expectedAccountGeneration = expectedAccountGeneration
        self.outgoingAccountID = outgoingAccountID
        self.capturedLocalAccountID = capturedLocalAccountID
        self.outgoingNormalCredentialLease = outgoingNormalCredentialLease
        self.outgoingAccountGeneration = outgoingAccountGeneration
        self.activationToken = activationToken
        self.outgoingAccountMutationPermit = outgoingAccountMutationPermit
        self.credentialTransition = credentialTransition
        self.drain = drain
    }
}
