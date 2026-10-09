import Foundation
import Testing
@testable import rishi

@MainActor
@Suite("Incoming book presentation readiness")
struct IncomingBookPresentationReadinessTests {
    private let identity = LibraryAccountIdentity(userID: UUID(), generation: 1)

    @Test("all five current empty reports are required for readiness")
    func requiresEveryOwner() {
        let state = IncomingBookPresentationReadiness(sceneID: UUID(), identity: identity)
        #expect(!state.isReady(for: identity))
        reportAll(state)
        #expect(state.isReady(for: identity))
    }

    @Test("only an idle first-book prompt permits preclaim")
    func preclaimIsNarrow() {
        let state = IncomingBookPresentationReadiness(sceneID: UUID(), identity: identity)
        reportAll(state)
        state.report(.libraryTab, identity: identity, blockers: [.idleFirstBookPrompt])
        #expect(!state.isReady(for: identity))
        #expect(state.isReadyForPreclaim(for: identity))
        state.report(.libraryRoot, identity: identity, blockers: [.deleteConfirmation])
        #expect(!state.isReadyForPreclaim(for: identity))
    }

    @Test("withdrawal, stale identity, and identity change fail closed")
    func staleAndMissingOwnersBlock() {
        let state = IncomingBookPresentationReadiness(sceneID: UUID(), identity: identity)
        reportAll(state)
        state.withdraw(.signedInContent)
        #expect(!state.isReady(for: identity))
        reportAll(state)
        let revision = state.revision
        let next = LibraryAccountIdentity(userID: identity.userID, generation: 2)
        state.report(.root, identity: identity, blockers: [])
        #expect(state.revision > revision)
        state.updateIdentity(next)
        #expect(!state.isReady(for: next))
    }

    @Test("stale owner cannot withdraw its replacement report")
    func replacementOwnerSurvivesOldTeardown() {
        let state = IncomingBookPresentationReadiness(sceneID: UUID(), identity: identity)
        for source in IncomingBookPresentationReadiness.Source.allCases where source != .libraryTab {
            state.report(source, identity: identity, blockers: [])
        }
        let old = state.claimOwnership(of: .libraryTab)
        let replacement = state.claimOwnership(of: .libraryTab)
        state.report(.libraryTab, identity: identity, blockers: [], owner: replacement)
        state.withdraw(.libraryTab, owner: old)
        state.withdraw(.libraryTab)
        #expect(state.isReady(for: identity))
    }

    @Test("incoming reader route is owner scoped and visible to trial eligibility")
    func incomingRouteOwnership() {
        let state = IncomingBookPresentationReadiness(sceneID: UUID(), identity: identity)
        let old = state.claimOwnership(of: .libraryTab)
        let replacement = state.claimOwnership(of: .libraryTab)
        state.setIncomingReaderRoutePresented(true, owner: old)
        #expect(!state.incomingReaderRoutePresented)
        state.setIncomingReaderRoutePresented(true, owner: replacement)
        #expect(state.incomingReaderRoutePresented)
        state.withdraw(.libraryTab, owner: old)
        #expect(state.incomingReaderRoutePresented)
        state.withdraw(.libraryTab, owner: replacement)
        #expect(!state.incomingReaderRoutePresented)
    }

    private func reportAll(_ state: IncomingBookPresentationReadiness) {
        for source in IncomingBookPresentationReadiness.Source.allCases {
            state.report(source, identity: identity, blockers: [])
        }
    }
}
