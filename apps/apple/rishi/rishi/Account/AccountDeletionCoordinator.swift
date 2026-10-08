import Foundation

enum AccountDeletionCoordinatorError: Error, Sendable {
    case accountChangedDuringDeletion
}

struct AccountDeletionCoordinator: Sendable {
    private struct LegacyOperations: Sendable {
        let deleteServer: @Sendable () async throws -> Void
        let purgeLocal: @Sendable () async throws -> Void
        let purgeLocalForGeneration: (@Sendable (UInt64) async throws -> BookImportActivationToken?)?
        let currentAccountGeneration: @Sendable () -> UInt64
        let reactivateLocalOwner: @MainActor @Sendable (BookImportActivationToken) async -> Void
        let beginAccountDeletionCleanup: @MainActor @Sendable (AccountChangeTransaction) -> Bool
        let endAccountDeletionCleanup: @MainActor @Sendable (AccountChangeTransaction) -> Void
        let signOut: @MainActor @Sendable () -> Void
        let beginAccountChange: (@MainActor @Sendable () throws -> AccountChangeTransaction)?

    }
    private struct CredentialOperations: Sendable {
        let deleteServer: @Sendable (AccountDeletionAdmission) async throws -> Void
        let purgeLocal: @MainActor @Sendable (AccountChangeTransaction) async throws -> Void
        let restoreOwner: @MainActor @Sendable (AccountChangeTransaction) async throws -> Void
        let isCurrent: @MainActor @Sendable (AccountChangeTransaction) -> Bool
        let beginCleanup: @MainActor @Sendable (AccountChangeTransaction) -> Bool
        let endCleanup: @MainActor @Sendable (AccountChangeTransaction) -> Void
        let signOut: @MainActor @Sendable (AccountChangeTransaction) async throws -> Void
        let beginChange: @MainActor @Sendable () throws -> AccountChangeTransaction
    }
    private enum Operations: Sendable {
        case legacy(LegacyOperations)
        case credential(CredentialOperations)
    }
    private let operations: Operations

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
        operations = .legacy(LegacyOperations(
            deleteServer: deleteServer,
            purgeLocal: purgeLocal,
            purgeLocalForGeneration: purgeLocalForGeneration,
            currentAccountGeneration: currentAccountGeneration,
            reactivateLocalOwner: reactivateLocalOwner,
            beginAccountDeletionCleanup: beginAccountDeletionCleanup,
            endAccountDeletionCleanup: endAccountDeletionCleanup,
            signOut: signOut,
            beginAccountChange: beginAccountChange
        ))
    }

    /// Staged captured-credential path. All operations are explicit and its
    /// sign-out completes within the original cleanup reservation.
    init(
        admittedDeleteServer: @escaping @Sendable (AccountDeletionAdmission) async throws -> Void,
        purgeLocal: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void,
        restoreOwner: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void,
        isCurrent: @escaping @MainActor @Sendable (AccountChangeTransaction) -> Bool,
        beginCleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) -> Bool,
        endCleanup: @escaping @MainActor @Sendable (AccountChangeTransaction) -> Void,
        signOut: @escaping @MainActor @Sendable (AccountChangeTransaction) async throws -> Void,
        beginChange: @escaping @MainActor @Sendable () throws -> AccountChangeTransaction
    ) {
        operations = .credential(CredentialOperations(
            deleteServer: admittedDeleteServer, purgeLocal: purgeLocal,
            restoreOwner: restoreOwner, isCurrent: isCurrent,
            beginCleanup: beginCleanup, endCleanup: endCleanup,
            signOut: signOut, beginChange: beginChange
        ))
    }

    @MainActor
    func run() async throws {
        switch operations {
        case .legacy(let legacy): try await runLegacy(legacy)
        case .credential(let scoped):
            let transaction = try scoped.beginChange()
            guard let admission = transaction.deletionAdmission else {
                throw CredentialAuthenticationFailure.reauthenticationRequired
            }
            await transaction.drain.value
            guard scoped.isCurrent(transaction) else { throw AccountDeletionCoordinatorError.accountChangedDuringDeletion }
            do { try await scoped.deleteServer(admission) }
            catch {
                if scoped.isCurrent(transaction) { try? await scoped.restoreOwner(transaction) }
                throw error
            }
            guard scoped.beginCleanup(transaction) else { throw AccountDeletionCoordinatorError.accountChangedDuringDeletion }
            defer { scoped.endCleanup(transaction) }
            do { try await scoped.purgeLocal(transaction) }
            catch {
                try await scoped.signOut(transaction)
                throw error
            }
            try await scoped.signOut(transaction)
        }
    }

    @MainActor
    func purgeLocalOnly() async throws {
        switch operations {
        case .legacy(let legacy): try await purgeLegacyLocalOnly(legacy)
        case .credential(let scoped):
            let transaction = try scoped.beginChange()
            await transaction.drain.value
            guard scoped.beginCleanup(transaction) else { throw AccountDeletionCoordinatorError.accountChangedDuringDeletion }
            defer { scoped.endCleanup(transaction) }
            do { try await scoped.purgeLocal(transaction) }
            catch {
                try? await scoped.restoreOwner(transaction)
                throw error
            }
            try await scoped.restoreOwner(transaction)
        }
    }

    @MainActor
    private func runLegacy(_ legacy: LegacyOperations) async throws {
        let transaction = try legacy.beginAccountChange?()
        let recoveryToken = transaction?.activationToken
        await transaction?.drain.value
        do {
            try await legacy.deleteServer()
        } catch {
            if let recoveryToken { await legacy.reactivateLocalOwner(recoveryToken) }
            throw error
        }
        if let transaction, !legacy.beginAccountDeletionCleanup(transaction) {
            throw AccountDeletionCoordinatorError.accountChangedDuringDeletion
        }
        do {
            if let purgeLocalForGeneration = legacy.purgeLocalForGeneration {
                _ = try await purgeLocalForGeneration(transaction?.outgoingAccountGeneration ?? legacy.currentAccountGeneration())
            } else {
                try await legacy.purgeLocal()
            }
        } catch {
            if let transaction { legacy.endAccountDeletionCleanup(transaction) }
            await legacy.signOut()
            throw error
        }
        if let transaction { legacy.endAccountDeletionCleanup(transaction) }
        await legacy.signOut()
    }

    /// DEBUG/E2E-only callers may need to reset a device without deleting a
    /// server account. Keep this separate from `run()` so a local reset cannot
    /// accidentally invoke the production deletion endpoint.
    @MainActor
    private func purgeLegacyLocalOnly(_ legacy: LegacyOperations) async throws {
        let transaction = try legacy.beginAccountChange?()
        await transaction?.drain.value
        let generation = transaction?.outgoingAccountGeneration ?? legacy.currentAccountGeneration()
        let transactionActivationToken = transaction?.activationToken
        if let purgeLocalForGeneration = legacy.purgeLocalForGeneration {
            do {
                let purgeActivationToken = try await purgeLocalForGeneration(generation)
                if let activationToken = transactionActivationToken ?? purgeActivationToken {
                    await legacy.reactivateLocalOwner(activationToken)
                }
            } catch {
                if let transactionActivationToken { await legacy.reactivateLocalOwner(transactionActivationToken) }
                throw error
            }
        } else {
            do {
                try await legacy.purgeLocal()
            } catch {
                if let transactionActivationToken { await legacy.reactivateLocalOwner(transactionActivationToken) }
                throw error
            }
            if let transactionActivationToken { await legacy.reactivateLocalOwner(transactionActivationToken) }
        }
    }
}
