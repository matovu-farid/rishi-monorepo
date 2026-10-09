import Foundation

/// Forward binding keeps materialization independent of UI observers and graph assembly order.
actor BookManagedReadySyncDispatcher {
    private weak var engine: SyncEngine?
    private let currentOwnerID: @Sendable () async -> UserID?
    private let currentGeneration: @Sendable () async -> UInt64?
    private var pending = Set<BookMaterializationToken>()
    private var configured = false

    init(currentOwnerID: @escaping @Sendable () async -> UserID?,
         currentGeneration: @escaping @Sendable () async -> UInt64?) {
        self.currentOwnerID = currentOwnerID
        self.currentGeneration = currentGeneration
    }

    func configure(engine: SyncEngine) async {
        guard !configured else { return }
        configured = true
        self.engine = engine
        let tokens = pending
        pending.removeAll()
        for token in tokens { await managedReady(token) }
    }

    func managedReady(_ token: BookMaterializationToken) async {
        guard await isCurrent(token) else { return }
        guard configured else { pending.insert(token); return }
        guard let engine, await isCurrent(token) else { return }
        await engine.requestSync()
    }

    private func isCurrent(_ token: BookMaterializationToken) async -> Bool {
        guard await currentOwnerID() == token.ownerID,
              await currentGeneration() == token.accountGeneration else { return false }
        return await currentOwnerID() == token.ownerID
    }
}
