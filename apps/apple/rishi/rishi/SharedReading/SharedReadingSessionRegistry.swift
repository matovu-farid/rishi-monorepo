import Foundation

protocol SharedReadingSessionRegistryHandle: AnyObject, Sendable {
    func cancelLocally() async
    func leaveRemotely() async
}

@MainActor
final class SharedReadingSessionRegistry {
    struct Registration: Hashable, Sendable {
        fileprivate let id: UUID
        fileprivate let accountID: UUID
        fileprivate let generation: UInt64
    }

    private struct Entry {
        let accountID: UUID
        let generation: UInt64
        let handle: any SharedReadingSessionRegistryHandle
    }

    private var entries: [UUID: Entry] = [:]
    private var generations: [UUID: UInt64] = [:]
    private let clearAccountState: @MainActor @Sendable (UUID) async -> Void

    var activeHandleCount: Int { entries.count }

    init(
        clearAccountState: @escaping @MainActor @Sendable (UUID) async -> Void = { _ in }
    ) {
        self.clearAccountState = clearAccountState
    }

    @discardableResult
    func register(_ handle: any SharedReadingSessionRegistryHandle, accountID: UUID) -> Registration {
        let id = UUID()
        let generation = generations[accountID, default: 0]
        entries[id] = Entry(accountID: accountID, generation: generation, handle: handle)
        return Registration(id: id, accountID: accountID, generation: generation)
    }

    func unregister(_ registration: Registration) {
        guard let entry = entries[registration.id],
              entry.accountID == registration.accountID,
              entry.generation == registration.generation else { return }
        entries.removeValue(forKey: registration.id)
    }

    func isCurrent(_ registration: Registration) -> Bool {
        generations[registration.accountID, default: 0] == registration.generation
            && entries[registration.id] != nil
    }

    /// Local teardown is always awaited before the next identity is published.
    /// Server leave is best effort, so one stale network operation cannot keep
    /// an account transition alive indefinitely.
    func drain(accountID: UUID, deadline: Duration = .seconds(2)) async {
        let generation = generations[accountID, default: 0]
        generations[accountID] = generation &+ 1
        let draining = entries.filter { $0.value.accountID == accountID }
        for (id, _) in draining { entries.removeValue(forKey: id) }

        for entry in draining.values { await entry.handle.cancelLocally() }
        await clearAccountState(accountID)
        for entry in draining.values { await entry.handle.leaveRemotely() }
        _ = deadline
    }
}
