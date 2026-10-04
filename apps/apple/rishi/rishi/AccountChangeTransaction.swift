import Foundation

/// Synchronous account-transition fence. Callers obtain this before creating
/// their own asynchronous cleanup task; the drain itself starts only after
/// the identity and generation fence has been committed.
@MainActor
final class AccountChangeTransaction {
    let expectedAccountGeneration: UInt64
    let drain: Task<Void, Never>
    let outgoingAccountID: UUID?
    let outgoingAccountGeneration: UInt64?
    let activationToken: BookImportActivationToken?
    let outgoingAccountMutationPermit: AccountMutationPermit?

    init(expectedAccountGeneration: UInt64, outgoingAccountID: UUID? = nil, outgoingAccountGeneration: UInt64? = nil, activationToken: BookImportActivationToken? = nil, outgoingAccountMutationPermit: AccountMutationPermit? = nil, drain: Task<Void, Never>) {
        self.expectedAccountGeneration = expectedAccountGeneration
        self.outgoingAccountID = outgoingAccountID
        self.outgoingAccountGeneration = outgoingAccountGeneration
        self.activationToken = activationToken
        self.outgoingAccountMutationPermit = outgoingAccountMutationPermit
        self.drain = drain
    }
}
