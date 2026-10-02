import Foundation

@MainActor
protocol SharedReadingSessionRegistryHandle: AnyObject {
    /// The registry claims the server leave before it starts local teardown.
    /// A view-owned cancellation can run after `cancelLocally()` has removed
    /// registration, so registration presence is not a safe ownership signal.
    func claimRegistryDrainRemoteLeaveOwnership()
    func cancelLocally() async
    func leaveRemotely() async
}

private actor SharedReadingRemoteLeaveTracker {
    private var remaining: Int

    init(count: Int) { remaining = count }

    func finished() { remaining -= 1 }
    func isFinished() -> Bool { remaining == 0 }
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
        Log.sharedReading(.registry, context: .init(outcome: .accepted, operationID: id))
        return Registration(id: id, accountID: accountID, generation: generation)
    }

    func unregister(_ registration: Registration) {
        guard let entry = entries[registration.id],
              entry.accountID == registration.accountID,
              entry.generation == registration.generation else { return }
        entries.removeValue(forKey: registration.id)
        Log.sharedReading(.registry, context: .init(outcome: .completed, operationID: registration.id))
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
        Log.sharedReading(.registry, context: .init(outcome: .started))
        for (id, _) in draining { entries.removeValue(forKey: id) }

        // Claim every remote leave before the first suspension point. Each
        // handle's local teardown unregisters itself, so the durable claim is
        // what prevents a concurrent recovery cancellation from stealing the
        // transition's bounded remote-leave responsibility.
        for entry in draining.values {
            entry.handle.claimRegistryDrainRemoteLeaveOwnership()
        }
        for entry in draining.values { await entry.handle.cancelLocally() }
        await clearAccountState(accountID)
        let tracker = SharedReadingRemoteLeaveTracker(count: draining.count)
        let leaves = draining.values.map { entry in
            Task { @MainActor [handle = entry.handle] in
                await handle.leaveRemotely()
                await tracker.finished()
            }
        }
        let clock = ContinuousClock()
        let expiresAt = clock.now.advanced(by: deadline)
        while !(await tracker.isFinished()) && clock.now < expiresAt {
            try? await Task.sleep(for: .milliseconds(5))
        }
        leaves.forEach { $0.cancel() }
        Log.sharedReading(.registry, context: .init(outcome: .completed))
    }
}
