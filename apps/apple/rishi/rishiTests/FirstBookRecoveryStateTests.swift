@testable import rishi
import Foundation
import Testing

@Suite("First book recovery state")
@MainActor
struct FirstBookRecoveryStateTests {
    @Test("recovery is a persistent account-scoped marker")
    func markerSurvivesStoreRecreationAndIsScopedToAccount() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstUser = UUID()
        let otherUser = UUID()
        let identity = LibraryAccountIdentity(userID: firstUser, generation: 7)
        let store = FirstBookRecoveryStore(defaults: defaults)

        #expect(store.hasRecovery(userID: firstUser) == false)
        #expect(store.hasRecovery(userID: otherUser) == false)
        #expect(store.setRecovery(true, identity: identity, currentIdentity: identity))

        // A new store models a relaunch: the account UUID owns persistence while
        // generation remains an in-memory write-admission fence.
        let relaunchedStore = FirstBookRecoveryStore(defaults: defaults)
        #expect(relaunchedStore.hasRecovery(userID: firstUser))
        #expect(relaunchedStore.hasRecovery(userID: otherUser) == false)
        #expect(defaults.object(forKey: FirstBookRecoveryStore.key(userID: firstUser)) as? Bool == true)
    }

    @Test("a stale generation cannot write or clear the current account marker")
    func generationMismatchRejectsBothMutations() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let userID = UUID()
        let oldIdentity = LibraryAccountIdentity(userID: userID, generation: 3)
        let currentIdentity = LibraryAccountIdentity(userID: userID, generation: 4)
        let store = FirstBookRecoveryStore(defaults: defaults)

        #expect(store.setRecovery(true, identity: currentIdentity, currentIdentity: currentIdentity))
        #expect(store.setRecovery(false, identity: oldIdentity, currentIdentity: currentIdentity) == false)
        #expect(store.hasRecovery(userID: userID))
        #expect(store.setRecovery(true, identity: oldIdentity, currentIdentity: currentIdentity) == false)
        #expect(store.hasRecovery(userID: userID))
    }

    @Test("cancelled and signed-out writes leave persisted recovery unchanged")
    func cancellationAndMissingIdentityRejectWrites() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let userID = UUID()
        let identity = LibraryAccountIdentity(userID: userID, generation: 11)
        let store = FirstBookRecoveryStore(defaults: defaults)

        #expect(store.setRecovery(true, identity: identity, currentIdentity: identity))
        #expect(store.setRecovery(false, identity: identity, currentIdentity: identity, isCancelled: true) == false)
        #expect(store.setRecovery(false, identity: identity, currentIdentity: nil) == false)
        #expect(store.hasRecovery(userID: userID))
    }

    @Test("an admitted current-generation clear removes only its account marker")
    func currentIdentityCanClearWithoutTouchingAnotherAccount() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = LibraryAccountIdentity(userID: UUID(), generation: 1)
        let second = LibraryAccountIdentity(userID: UUID(), generation: 1)
        let store = FirstBookRecoveryStore(defaults: defaults)
        #expect(store.setRecovery(true, identity: first, currentIdentity: first))
        #expect(store.setRecovery(true, identity: second, currentIdentity: second))

        #expect(store.setRecovery(false, identity: first, currentIdentity: first))
        #expect(store.hasRecovery(userID: first.userID) == false)
        #expect(store.hasRecovery(userID: second.userID))
    }

    @Test("recovery reads current defaults after another host changes the account marker")
    func anotherHostMarkerChangesAreObservedOnRead() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let userID = UUID()
        let key = FirstBookRecoveryStore.key(userID: userID)
        let store = FirstBookRecoveryStore(defaults: defaults)

        defaults.set(true, forKey: key)
        #expect(store.hasRecovery(userID: userID))
        defaults.set(false, forKey: key)
        #expect(store.hasRecovery(userID: userID) == false)
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FirstBookRecoveryStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
