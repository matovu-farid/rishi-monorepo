import Foundation

enum AccountDeletionCoordinatorError: Error, Sendable {
    case accountChangedDuringDeletion
}

struct AccountDeletionCoordinator: Sendable {
    private let deleteServer: @Sendable () async throws -> Void
    private let purgeLocal: @Sendable () async throws -> Void
    private let purgeLocalForGeneration: (@Sendable (UInt64) async throws -> BookImportActivationToken?)?
    private let currentAccountGeneration: @Sendable () -> UInt64
    private let reactivateLocalOwner: @MainActor @Sendable (BookImportActivationToken) async -> Void
    private let beginAccountDeletionCleanup: @MainActor @Sendable (AccountChangeTransaction) -> Bool
    private let endAccountDeletionCleanup: @MainActor @Sendable (AccountChangeTransaction) -> Void
    private let signOut: @MainActor @Sendable () -> Void
    private let beginAccountChange: (@MainActor @Sendable () throws -> AccountChangeTransaction)?

    init(
        deleteServer: @escaping @Sendable () async throws -> Void,
        purgeLocal: @escaping @Sendable () async throws -> Void,
        purgeLocalForGeneration: (@Sendable (UInt64) async throws -> BookImportActivationToken?)? = nil,
        currentAccountGeneration: @escaping @Sendable () -> UInt64 = { 0 },
        reactivateLocalOwner: @escaping @MainActor @Sendable (BookImportActivationToken) async -> Void = { _ in },
        beginAccountDeletionCleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) -> Bool = { _ in true },
        endAccountDeletionCleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) -> Void = { _ in },
        signOut: @escaping @MainActor @Sendable () -> Void,
        beginAccountChange: (@MainActor @Sendable () throws -> AccountChangeTransaction)? = nil
    ) {
        self.deleteServer = deleteServer
        self.purgeLocal = purgeLocal
        self.purgeLocalForGeneration = purgeLocalForGeneration
        self.currentAccountGeneration = currentAccountGeneration
        self.reactivateLocalOwner = reactivateLocalOwner
        self.beginAccountDeletionCleanup = beginAccountDeletionCleanup
        self.endAccountDeletionCleanup = endAccountDeletionCleanup
        self.signOut = signOut
        self.beginAccountChange = beginAccountChange
    }

    @MainActor
    func run() async throws {
        let transaction = try beginAccountChange?()
        let recoveryToken = transaction?.activationToken
        await transaction?.drain.value
        do {
            try await deleteServer()
        } catch {
            if let recoveryToken { await reactivateLocalOwner(recoveryToken) }
            throw error
        }
        if let transaction, !beginAccountDeletionCleanup(transaction) {
            throw AccountDeletionCoordinatorError.accountChangedDuringDeletion
        }
        do {
            if let purgeLocalForGeneration {
                _ = try await purgeLocalForGeneration(transaction?.outgoingAccountGeneration ?? currentAccountGeneration())
            } else {
                try await purgeLocal()
            }
        } catch {
            if let transaction { endAccountDeletionCleanup(transaction) }
            await signOut()
            throw error
        }
        if let transaction { endAccountDeletionCleanup(transaction) }
        await signOut()
    }

    /// DEBUG/E2E-only callers may need to reset a device without deleting a
    /// server account. Keep this separate from `run()` so a local reset cannot
    /// accidentally invoke the production deletion endpoint.
    @MainActor
    func purgeLocalOnly() async throws {
        let transaction = try beginAccountChange?()
        await transaction?.drain.value
        let generation = transaction?.outgoingAccountGeneration ?? currentAccountGeneration()
        let transactionActivationToken = transaction?.activationToken
        if let purgeLocalForGeneration {
            do {
                let purgeActivationToken = try await purgeLocalForGeneration(generation)
                if let activationToken = transactionActivationToken ?? purgeActivationToken {
                    await reactivateLocalOwner(activationToken)
                }
            } catch {
                if let transactionActivationToken { await reactivateLocalOwner(transactionActivationToken) }
                throw error
            }
        } else {
            do {
                try await purgeLocal()
            } catch {
                if let transactionActivationToken { await reactivateLocalOwner(transactionActivationToken) }
                throw error
            }
            if let transactionActivationToken { await reactivateLocalOwner(transactionActivationToken) }
        }
    }
}
