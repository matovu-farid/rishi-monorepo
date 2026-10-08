@testable import rishi
import Foundation
import Testing

@Suite("No card trial presentation policy")
struct NoCardTrialPresentationPolicyTests {
    @Test("missing child state and each root safety condition fail closed")
    func missingOrUnsafeRootFactsDenyChecks() {
        var value = snapshot()
        value.child = nil
        #expect(!NoCardTrialPresentationPolicy.permitsCheck(value))

        let unsafeRootFacts: [(String, (inout TrialIntroPresentationSnapshot) -> Void)] = [
            ("host", { $0.hostActive = false }),
            ("scene", { $0.sceneActive = false }),
            ("navigation", { $0.rootPathEmpty = false }),
            ("shared reader", { $0.sharedReaderAbsent = false }),
            ("Catalyst reader", { $0.catalystReaderWindowsAbsent = false }),
            ("root presentation", { $0.rootPresentation = .other }),
            ("restore", { $0.restoreActive = true }),
            ("native presentation", { $0.nativePresentationActive = true })
        ]

        for (name, mutate) in unsafeRootFacts {
            var candidate = snapshot()
            mutate(&candidate)
            #expect(!NoCardTrialPresentationPolicy.permitsCheck(candidate), "Unsafe \(name) state must deny a trial check")
        }
    }

    @Test("every child modal or active first book flow denies")
    func childCompetitorsDenyChecks() {
        let unsafeChildFacts: [(String, (inout TrialChildSafety) -> Void)] = [
            ("signed out", { $0.signedIn = false }),
            ("consent loading", { $0.consent = false }),
            ("conversation", { $0.conversation = false }),
            ("voice", { $0.voice = false }),
            ("library loading", { $0.libraryReady = false }),
            ("library modal", { $0.libraryModal = false }),
            ("first book flow", { $0.firstBookFlowActive = true })
        ]

        for (name, mutate) in unsafeChildFacts {
            var candidate = snapshot()
            var child = try! #require(candidate.child)
            mutate(&child)
            candidate.child = child
            #expect(!NoCardTrialPresentationPolicy.permitsCheck(candidate), "Unsafe \(name) state must deny a trial check")
        }
    }

    @Test("appearance requires the exact claim, identity, revision, and safe facts")
    func appearanceRequiresExactClaimAndCurrentFacts() {
        let claimID = UUID()
        let identity = accountIdentity()
        var candidate = snapshot(identity: identity, revision: 12)
        candidate.rootPresentation = .claimedTrialIntro(claimID)
        #expect(NoCardTrialPresentationPolicy.permitsAppearance(candidate, claimID: claimID, identity: identity, revision: 12))
        #expect(!NoCardTrialPresentationPolicy.permitsAppearance(candidate, claimID: UUID(), identity: identity, revision: 12))
        #expect(!NoCardTrialPresentationPolicy.permitsAppearance(candidate, claimID: claimID, identity: accountIdentity(), revision: 12))
        #expect(!NoCardTrialPresentationPolicy.permitsAppearance(candidate, claimID: claimID, identity: identity, revision: 13))

        candidate.child?.firstBookFlowActive = true
        #expect(!NoCardTrialPresentationPolicy.permitsAppearance(candidate, claimID: claimID, identity: identity, revision: 12))
    }

    @Test("new root competitors override the exact claimed cover")
    func rootCompetitorClassificationPrioritizesOtherPresentation() {
        let claimID = UUID()
        #expect(NoCardTrialPresentationPolicy.rootPresentation(
            trialCoverPresented: true, trialClaimID: claimID,
            competingPresentationActive: false
        ) == .claimedTrialIntro(claimID))
        #expect(NoCardTrialPresentationPolicy.rootPresentation(
            trialCoverPresented: true, trialClaimID: claimID,
            competingPresentationActive: true
        ) == .other)
        #expect(NoCardTrialPresentationPolicy.rootPresentation(
            trialCoverPresented: true, trialClaimID: nil,
            competingPresentationActive: false
        ) == .other)
    }

    @Test("only one pending safe changed-revision result retries")
    func changedSafetyRevisionSchedulesOneRetry() {
        let safe = snapshot(revision: 8)
        #expect(NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
            outcome: .factsChanged, attemptedRevision: 7,
            currentSnapshot: safe, hasPendingReadiness: true
        ))
        // The enqueued retry settles on revision 8; its own unchanged notification cannot enqueue again.
        #expect(!NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
            outcome: .factsChanged, attemptedRevision: 8,
            currentSnapshot: safe, hasPendingReadiness: true
        ))
        #expect(NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
            outcome: .cancelled, attemptedRevision: 7,
            currentSnapshot: safe, hasPendingReadiness: true
        ))
        #expect(!NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
            outcome: .factsChanged, attemptedRevision: 8,
            currentSnapshot: safe, hasPendingReadiness: true
        ))
        #expect(!NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
            outcome: .presentationRefused, attemptedRevision: 7,
            currentSnapshot: safe, hasPendingReadiness: true
        ))
        #expect(!NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
            outcome: .factsChanged, attemptedRevision: 7,
            currentSnapshot: snapshot(revision: 8, sceneActive: false), hasPendingReadiness: true
        ))
        #expect(!NoCardTrialPresentationPolicy.shouldRetryAfterSafetyRevisionChange(
            outcome: .factsChanged, attemptedRevision: 7,
            currentSnapshot: safe, hasPendingReadiness: false
        ))
    }

    @Test("Catalyst username and account-deletion presentations block the signed-in source")
    func signedInSourceRejectsAccountAndModalCompetitors() {
        let safe = NoCardTrialPresentationPolicy.signedInSourceIsSafe(
            accountMatches: true,
            catalystModelAvailable: true,
            usernameEditorPresented: false,
            accountDeleteConfirmationPresented: false,
            accountDeleteErrorPresented: false
        )
        #expect(safe)

        let unsafe: [(String, Bool, Bool, Bool, Bool, Bool)] = [
            ("account", false, true, false, false, false),
            ("missing Catalyst model", true, false, false, false, false),
            ("username editor", true, true, true, false, false),
            ("delete confirmation", true, true, false, true, false),
            ("delete error", true, true, false, false, true)
        ]
        for (name, accountMatches, modelAvailable, usernameEditor, deleteConfirmation, deleteError) in unsafe {
            #expect(!NoCardTrialPresentationPolicy.signedInSourceIsSafe(
                accountMatches: accountMatches,
                catalystModelAvailable: modelAvailable,
                usernameEditorPresented: usernameEditor,
                accountDeleteConfirmationPresented: deleteConfirmation,
                accountDeleteErrorPresented: deleteError
            ), "\(name) must deny a trial check")
        }
    }

    @Test("an older attempt cannot settle newer same-account generation readiness")
    func staleAttemptCannotSettleNewGeneration() {
        let userID = UUID()
        let attemptA = LibraryAccountIdentity(userID: userID, generation: 4)
        let currentB = LibraryAccountIdentity(userID: userID, generation: 5)
        #expect(NoCardTrialPresentationPolicy.shouldSettleAttempt(
            attemptIdentity: attemptA, currentIdentity: attemptA,
            pendingReadyIdentity: attemptA
        ))
        #expect(!NoCardTrialPresentationPolicy.shouldSettleAttempt(
            attemptIdentity: attemptA, currentIdentity: currentB,
            pendingReadyIdentity: currentB
        ))
        #expect(!NoCardTrialPresentationPolicy.shouldSettleAttempt(
            attemptIdentity: attemptA, currentIdentity: currentB,
            pendingReadyIdentity: nil
        ))
        #expect(!NoCardTrialPresentationPolicy.shouldSettleAttempt(
            attemptIdentity: currentB, currentIdentity: currentB,
            pendingReadyIdentity: attemptA
        ))
    }

    @Test("an old completion cannot clear a newer in-flight attempt token")
    func staleAttemptCompletionCannotSuppressSuccessor() {
        let attemptA = UUID()
        let attemptB = UUID()
        #expect(NoCardTrialPresentationPolicy.isCurrentAttempt(
            completedAttemptID: attemptA, activeAttemptID: attemptA
        ))
        #expect(!NoCardTrialPresentationPolicy.isCurrentAttempt(
            completedAttemptID: attemptA, activeAttemptID: attemptB
        ))
        #expect(!NoCardTrialPresentationPolicy.isCurrentAttempt(
            completedAttemptID: attemptA, activeAttemptID: nil
        ))
    }
}

private func snapshot(
    identity: LibraryAccountIdentity? = accountIdentity(),
    revision: UInt64 = 1,
    sceneActive: Bool = true
) -> TrialIntroPresentationSnapshot {
    TrialIntroPresentationSnapshot(
        hostID: UUID(),
        identity: identity,
        revision: revision,
        hostActive: true,
        sceneActive: sceneActive,
        rootPathEmpty: true,
        sharedReaderAbsent: true,
        catalystReaderWindowsAbsent: true,
        rootPresentation: .none,
        child: TrialChildSafety(
            signedIn: true,
            consent: true,
            conversation: true,
            voice: true,
            libraryReady: true,
            libraryModal: true,
            firstBookFlowActive: false
        ),
        restoreActive: false,
        nativePresentationActive: false
    )
}

private func accountIdentity() -> LibraryAccountIdentity {
    LibraryAccountIdentity(userID: UUID(), generation: 1)
}
