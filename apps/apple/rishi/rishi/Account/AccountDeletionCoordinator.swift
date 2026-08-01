import Foundation

struct AccountDeletionCoordinator: Sendable {
    private let deleteServer: @Sendable () async throws -> Void
    private let purgeLocal: @Sendable () async throws -> Void
    private let signOut: @MainActor @Sendable () -> Void

    init(
        deleteServer: @escaping @Sendable () async throws -> Void,
        purgeLocal: @escaping @Sendable () async throws -> Void,
        signOut: @escaping @MainActor @Sendable () -> Void
    ) {
        self.deleteServer = deleteServer
        self.purgeLocal = purgeLocal
        self.signOut = signOut
    }

    func run() async throws {
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
