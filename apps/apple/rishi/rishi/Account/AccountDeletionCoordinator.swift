import Foundation

struct AccountDeletionCoordinator: Sendable {
    private let deleteServer: @Sendable () async throws -> Void
    private let purgeLocal: @Sendable () async throws -> Void
    private let signOut: @MainActor @Sendable () -> Void
    private let beginAccountChange: (@MainActor @Sendable () throws -> AccountChangeTransaction)?

    init(
        deleteServer: @escaping @Sendable () async throws -> Void,
        purgeLocal: @escaping @Sendable () async throws -> Void,
        signOut: @escaping @MainActor @Sendable () -> Void,
        beginAccountChange: (@MainActor @Sendable () throws -> AccountChangeTransaction)? = nil
    ) {
        self.deleteServer = deleteServer
        self.purgeLocal = purgeLocal
        self.signOut = signOut
        self.beginAccountChange = beginAccountChange
    }

    @MainActor
    func run() async throws {
        let transaction = try beginAccountChange?()
        await transaction?.drain.value
        try await deleteServer()
        do {
            try await purgeLocal()
        } catch {
            await signOut()
            throw error
        }
        await signOut()
    }
}
