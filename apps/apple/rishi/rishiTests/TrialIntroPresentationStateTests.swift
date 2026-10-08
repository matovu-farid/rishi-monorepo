@testable import rishi
import Foundation
import Testing

@MainActor
@Suite("Trial intro presentation state")
struct TrialIntroPresentationStateTests {
    @Test("bridge starts fail closed and requires every current child source")
    func requiredSourcesFailClosed() {
        let identity = accountIdentity()
        let state = TrialIntroPresentationState()
        state.registerRoot { rootSnapshot(identity: identity, hostID: state.hostID) }
        state.requestLibraryReady(identity: identity)

        #expect(state.snapshot()?.child == nil)
        #expect(state.hasPendingReady)
        registerOtherRequiredSources(in: state, identity: identity)
        #expect(state.snapshot()?.child != nil)
        #expect(state.snapshot()?.permitsCheck == false)
        registerClearPurchaseErrorProvider(in: state)
        #expect(state.snapshot()?.permitsCheck == true)
    }

    @Test("live providers are read when taking the snapshot")
    func providerChangesAreVisibleWithoutCachedCopies() {
        let identity = accountIdentity()
        let state = TrialIntroPresentationState()
        state.registerRoot { rootSnapshot(identity: identity, hostID: state.hostID) }
        registerClearPurchaseErrorProvider(in: state)
        for source in [TrialIntroPresentationState.Source.signedIn,
                       .signedInContent, .libraryRoot] {
            state.register(source, identity: identity) { childSafety() }
        }
        var modalActive = false
        let registration = state.register(.library, identity: identity) {
            childSafety(libraryModal: !modalActive)
        }

        let before = state.snapshot()?.revision
        #expect(state.snapshot()?.permitsCheck == true)
        modalActive = true
        let changed = state.snapshot()
        #expect(changed?.permitsCheck == false)
        #expect(changed?.revision != before)
        let unchanged = state.snapshot()?.revision
        #expect(unchanged == changed?.revision)
        state.unregister(registration)
        #expect(state.snapshot()?.child == nil)
    }

    @Test("the account-independent live purchase-error provider blocks and clears safely")
    func purchaseErrorProviderIsReadLive() {
        let identity = accountIdentity()
        let state = TrialIntroPresentationState()
        state.registerRoot { rootSnapshot(identity: identity, hostID: state.hostID) }
        registerOtherRequiredSources(in: state, identity: identity)
        let source = NSObject()
        var blocking = false
        state.registerPurchaseError(source: source) { blocking }

        #expect(state.snapshot()?.permitsCheck == true)
        blocking = true
        #expect(state.snapshot()?.permitsCheck == false)
        state.unregisterPurchaseError(source: source)
        #expect(state.snapshot()?.permitsCheck == false) // missing provider fails closed
        state.registerPurchaseError(source: source) { false }
        #expect(state.snapshot()?.permitsCheck == true)
    }

    @Test("old generation cleanup cannot remove the current generation report or readiness")
    func staleGenerationCleanupDoesNotClearNewerState() {
        let userID = UUID()
        let oldIdentity = LibraryAccountIdentity(userID: userID, generation: 1)
        let currentIdentity = LibraryAccountIdentity(userID: userID, generation: 2)
        let state = TrialIntroPresentationState()
        var current = rootSnapshot(identity: currentIdentity, hostID: state.hostID)
        state.registerRoot { current }
        registerClearPurchaseErrorProvider(in: state)
        state.requestLibraryReady(identity: currentIdentity)
        let stale = state.register(.library, identity: oldIdentity) { childSafety() }
        registerOtherRequiredSources(in: state, identity: currentIdentity)
        let currentLibrary = state.register(.library, identity: currentIdentity) { childSafety() }

        state.unregister(stale)
        state.setRecoveryActive(true, identity: oldIdentity)
        state.consumeReady(identity: oldIdentity)

        #expect(state.pendingReadyIdentity == currentIdentity)
        #expect(state.snapshot()?.child != nil)
        #expect(state.snapshot()?.permitsCheck == true)

        state.unregister(currentLibrary)
        current.identity = oldIdentity
        #expect(state.snapshot()?.child == nil)
    }

    @Test("unsafe readiness remains pending until an explicit matching consumption")
    func readinessIsRetainedWhileUnsafe() {
        let identity = accountIdentity()
        let state = makeReadyState(identity: identity)
        state.requestLibraryReady(identity: identity)
        state.setRecoveryActive(true, identity: identity)

        #expect(state.snapshot()?.permitsCheck == false)
        #expect(state.pendingReadyIdentity == identity)

        state.setRecoveryActive(false, identity: identity)
        #expect(state.snapshot()?.permitsCheck == true)
        #expect(state.pendingReadyIdentity == identity)
        state.consumeReady(identity: identity)
        #expect(state.pendingReadyIdentity == nil)
    }

    @Test("legacy sample activity is registered synchronously and overlapping completion removes only its token")
    func legacySampleTokensSpanTheDismissalGapAndOverlap() {
        let identity = accountIdentity()
        let tracker = TrialLegacySampleOperationTracker()

        let first = tracker.begin(identity: identity)
        #expect(tracker.isActive(for: identity)) // onUseSample records before sheet dismissal/Task creation
        let second = tracker.begin(identity: identity)
        #expect(tracker.operationIDs == [first, second])

        #expect(tracker.finish(first, identity: identity, currentIdentity: identity))
        #expect(tracker.isActive(for: identity))
        #expect(tracker.operationIDs == [second])
        #expect(tracker.finish(second, identity: identity, currentIdentity: identity))
        #expect(!tracker.isActive(for: identity))
    }

    @Test("stale account or operation completion cannot clear the current sample activity")
    func staleLegacySampleCompletionCannotClearReplacement() {
        let userID = UUID()
        let oldIdentity = LibraryAccountIdentity(userID: userID, generation: 4)
        let currentIdentity = LibraryAccountIdentity(userID: userID, generation: 5)
        let tracker = TrialLegacySampleOperationTracker()
        let oldToken = tracker.begin(identity: oldIdentity)
        let currentToken = tracker.begin(identity: currentIdentity)

        #expect(!tracker.finish(oldToken, identity: oldIdentity, currentIdentity: currentIdentity))
        #expect(tracker.isActive(for: currentIdentity))
        #expect(tracker.operationIDs == [currentToken])
        #expect(!tracker.finish(currentToken, identity: oldIdentity, currentIdentity: oldIdentity))
        #expect(tracker.isActive(for: currentIdentity))
    }

    @Test("provider hidden by its own cover stays live until exact dismissal, then its retirement drains")
    func ownCoverDefersExactProviderRetirement() {
        let identity = accountIdentity()
        let state = TrialIntroPresentationState()
        var presentation: TrialRootPresentation = .none
        var sceneActive = true
        var childModal = false
        state.registerRoot {
            var snapshot = rootSnapshot(identity: identity, hostID: state.hostID)
            snapshot.rootPresentation = presentation
            snapshot.sceneActive = sceneActive
            return snapshot
        }
        registerClearPurchaseErrorProvider(in: state)
        let registrations = [TrialIntroPresentationState.Source.signedIn,
                            .signedInContent, .library, .libraryRoot].map { source in
            state.register(source, identity: identity) {
                childSafety(libraryModal: !childModal)
            }
        }
        let claimID = UUID()
        state.setOwnedCover(claimID)
        presentation = .claimedTrialIntro(claimID)
        state.update()

        registrations.forEach { state.unregister($0, deferredUnderCover: claimID) }
        let underCover = state.snapshot()
        #expect(underCover?.child != nil)
        #expect(underCover.map {
            NoCardTrialPresentationPolicy.permitsAppearance(
                $0, claimID: claimID, identity: identity, revision: $0.revision
            )
        } == true)
        sceneActive = false
        #expect(state.snapshot().map {
            NoCardTrialPresentationPolicy.permitsAppearance(
                $0, claimID: claimID, identity: identity, revision: underCover!.revision
            )
        } == false)
        sceneActive = true
        childModal = true
        #expect(state.snapshot()?.permitsCheck == false)

        state.coverDidDismiss(claimID: UUID())
        #expect(state.snapshot()?.child != nil)
        let replacement = state.register(.library, identity: identity) { childSafety() }
        presentation = .none
        state.coverDidDismiss(claimID: claimID)
        // The other three registrations were also retired when the owned cover dismissed.
        // A complete fresh source set makes the replacement library registration observable.
        for source in [TrialIntroPresentationState.Source.signedIn,
                       .signedInContent, .libraryRoot] {
            state.register(source, identity: identity) { childSafety() }
        }
        #expect(state.snapshot()?.child != nil)
        state.unregister(replacement)
        #expect(state.snapshot()?.child == nil)
    }

    @Test("transient window detach retains exact scene authority but graph retirement under cover fails closed")
    func lifetimeAuthorityRetainsDetachAndRejectsRetiredCoveredHost() {
        let identity = accountIdentity()
        let hostID = UUID()
        let graphID = UUID()
        let sceneID = UUID()
        let authority = TrialRootLifetimeAuthority()
        let state = TrialIntroPresentationState(hostID: hostID)
        var presentation: TrialRootPresentation = .none
        state.registerRoot {
            var snapshot = rootSnapshot(identity: identity, hostID: hostID)
            let facts = authority.snapshotFacts(hostID: hostID, graphID: graphID,
                                                localSceneIsActive: true)
            snapshot.hostActive = facts.hostActive
            snapshot.sceneActive = facts.sceneActive
            snapshot.rootPresentation = presentation
            return snapshot
        }
        registerOtherRequiredSources(in: state, identity: identity)
        registerClearPurchaseErrorProvider(in: state)
        state.requestLibraryReady(identity: identity)

        #expect(state.snapshot()?.permitsCheck == false) // no current anchor is fail closed
        let anchor = authority.register(hostID: hostID, graphID: graphID,
                                        sceneID: sceneID, sceneActive: false)
        state.update()
        #expect(state.snapshot()?.hostActive == true)
        #expect(state.snapshot()?.sceneActive == false) // no authoritative active scene yet
        #expect(authority.setSceneActive(anchor, active: true))
        state.update()
        #expect(state.snapshot()?.permitsCheck == true)

        let claimID = UUID()
        state.setOwnedCover(claimID)
        presentation = .claimedTrialIntro(claimID)
        state.update()
        let beforeDetach = authority.snapshotFacts(hostID: hostID, graphID: graphID,
                                                   localSceneIsActive: true)
        #expect(authority.retainAfterTransientWindowDetach(anchor))
        #expect(authority.currentAnchor?.sceneID == sceneID)
        #expect(authority.snapshotFacts(hostID: hostID, graphID: graphID,
                                        localSceneIsActive: true) == beforeDetach)
        let underCover = state.snapshot()
        #expect(underCover.map {
            NoCardTrialPresentationPolicy.permitsAppearance(
                $0, claimID: claimID, identity: identity, revision: $0.revision
            )
        } == true)

        #expect(authority.retire(anchor)) // true graph dismantle retires despite owned cover
        state.update()
        let retired = state.snapshot()
        #expect(retired?.hostActive == false)
        #expect(retired.map {
            NoCardTrialPresentationPolicy.permitsAppearance(
                $0, claimID: claimID, identity: identity, revision: underCover!.revision
            )
        } == false)
    }

    @Test("only the current graph anchor and its exact scene can retire the host")
    func lifetimeAuthorityUsesExactAnchorAndScene() {
        let authority = TrialRootLifetimeAuthority()
        let hostID = UUID()
        let sceneA = UUID()
        let sceneB = UUID()
        let old = authority.register(hostID: hostID, graphID: UUID(), sceneID: sceneA)

        #expect(!authority.sceneDidDisconnect(anchor: old, sceneID: sceneB))
        #expect(authority.currentAnchor == old)
        let replacement = authority.register(hostID: hostID, graphID: UUID(), sceneID: sceneB)
        #expect(!authority.retire(old))
        #expect(!authority.sceneDidDisconnect(anchor: old, sceneID: sceneA))
        #expect(authority.currentAnchor == replacement)
        #expect(authority.sceneDidDisconnect(anchor: replacement, sceneID: sceneB))
        #expect(authority.currentAnchor == nil)
    }

    @Test("owned-cover hiding defers retirement and exact dismissal drains it")
    func lifetimeAuthorityDefersOwnedCoverRetirement() {
        let authority = TrialRootLifetimeAuthority()
        let hostID = UUID()
        let anchor = authority.register(hostID: hostID, graphID: UUID(), sceneID: UUID())

        #expect(authority.deferRetirement(anchor))
        #expect(!authority.ownedCoverDidDismiss(hostID: UUID()))
        #expect(authority.currentAnchor == anchor)
        #expect(authority.ownedCoverDidDismiss(hostID: hostID))
        #expect(authority.currentAnchor == nil)
        let replacement = authority.register(hostID: hostID, graphID: UUID(), sceneID: UUID())
        #expect(!authority.ownedCoverDidDismiss(hostID: hostID))
        #expect(authority.currentAnchor == replacement)
    }

    @Test("queued anchor change and retirement callbacks cannot act on a replacement host")
    func queuedAnchorCallbacksAreRegistrationExact() {
        let authority = TrialRootLifetimeAuthority()
        let hostID = UUID()
        let graphID = UUID()
        let old = authority.register(hostID: hostID, graphID: graphID, sceneID: UUID())

        #expect(authority.isCurrent(old)) // update notification queued for this registration
        #expect(authority.retire(old))
        #expect(authority.isLatestRetired(old)) // retirement notification queued

        let replacement = authority.register(hostID: hostID, graphID: graphID, sceneID: UUID())
        #expect(!authority.isCurrent(old))
        #expect(authority.isCurrent(replacement))
        #expect(!authority.isLatestRetired(old))
        #expect(authority.currentAnchor == replacement)

        #expect(authority.retire(replacement))
        #expect(authority.isLatestRetired(replacement))
    }
}

@MainActor
private func makeReadyState(identity: LibraryAccountIdentity) -> TrialIntroPresentationState {
    let state = TrialIntroPresentationState()
    state.registerRoot { rootSnapshot(identity: identity, hostID: state.hostID) }
    registerOtherRequiredSources(in: state, identity: identity)
    registerClearPurchaseErrorProvider(in: state)
    return state
}

@MainActor
private func registerOtherRequiredSources(in state: TrialIntroPresentationState, identity: LibraryAccountIdentity) {
    for source in [TrialIntroPresentationState.Source.signedIn,
                   .signedInContent, .library, .libraryRoot] {
        state.register(source, identity: identity) { childSafety() }
    }
}

@MainActor
private func registerClearPurchaseErrorProvider(in state: TrialIntroPresentationState) {
    state.registerPurchaseError(source: NSObject()) { false }
}

private func childSafety(libraryModal: Bool = true) -> TrialChildSafety {
    TrialChildSafety(signedIn: true, consent: true, conversation: true, voice: true,
                     libraryReady: true, libraryModal: libraryModal, firstBookFlowActive: false)
}

func rootSnapshot(identity: LibraryAccountIdentity?, hostID: UUID) -> TrialIntroPresentationSnapshot {
    TrialIntroPresentationSnapshot(hostID: hostID, identity: identity, revision: 0,
                                   hostActive: true, sceneActive: true, rootPathEmpty: true,
                                   sharedReaderAbsent: true, catalystReaderWindowsAbsent: true,
                                   rootPresentation: .none, child: nil, restoreActive: false,
                                   nativePresentationActive: false)
}

private func accountIdentity() -> LibraryAccountIdentity {
    LibraryAccountIdentity(userID: UUID(), generation: 1)
}
