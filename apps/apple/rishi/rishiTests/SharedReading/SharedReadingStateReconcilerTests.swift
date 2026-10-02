import Foundation
import Testing

@testable import rishi

@Suite("Shared reading state reconciliation")
struct SharedReadingStateReconcilerTests {
    private func authority(sequence: Int64 = 1) -> SharedReadingAuthorityRevision {
        SharedReadingAuthorityRevision(
            sessionId: "session",
            roomEpoch: 3,
            controllerGeneration: 4,
            connectionGeneration: 5,
            progressSequence: sequence
        )
    }

    private func position(_ progression: Double, href: String = "chapter-1.xhtml", page: Int? = 2) -> SharedReadingPosition {
        SharedReadingPosition(href: href, page: page, progression: progression)
    }

    private func input(
        sequence: Int64 = 1,
        desiredPosition: SharedReadingPosition = .init(href: "chapter-1.xhtml", page: 2, progression: 0.4),
        source: SharedReadingDesiredPosition.Source = .reader,
        desiredPlayback: SharedReadingDesiredPlayback = .paused,
        desiredRate: Double = 1.25,
        visiblePosition: SharedReadingPosition? = .init(href: "chapter-1.xhtml", page: 2, progression: 0.4),
        narrationPosition: SharedReadingPosition? = nil,
        playback: SharedReadingObservedPlayback = .noSession,
        effectiveRate: Double? = 1.25
    ) -> SharedReadingReconcileInput {
        SharedReadingReconcileInput(
            authority: authority(sequence: sequence),
            desiredPosition: SharedReadingDesiredPosition(position: desiredPosition, source: source),
            desiredPlayback: desiredPlayback,
            desiredRate: desiredRate,
            visiblePosition: visiblePosition,
            narrationPosition: narrationPosition,
            playback: playback,
            effectiveRate: effectiveRate
        )
    }

    private func matchingObservation(for input: SharedReadingReconcileInput) -> SharedReadingLocalObservation {
        SharedReadingLocalObservation(
            visiblePosition: input.visiblePosition,
            narrationPosition: input.narrationPosition,
            playback: input.playback,
            effectiveRate: input.effectiveRate
        )
    }

    private func containsPositionEffect(
        _ effects: [SharedReadingEffect],
        matching target: SharedReadingPosition,
        where matches: (SharedReadingEffect) -> SharedReadingPosition?
    ) -> Bool {
        effects.contains { matches($0) == target }
    }

    @Test("an already paused follower emits no pause, start, or rate effect")
    func alreadyPausedDoesNotRepeatPlaybackOrRateEffects() {
        let session = UUID()
        var reconciler = SharedReadingStateReconciler()
        let state = input(
            playback: .paused(session),
            narrationPosition: position(0.4)
        )

        #expect(reconciler.reconcile(state).isEmpty)
    }

    @Test("an already playing follower does not restart narration")
    func alreadyPlayingDoesNotRestartNarration() {
        let session = UUID()
        var reconciler = SharedReadingStateReconciler()
        let state = input(
            source: .readAloud,
            desiredPlayback: .playing,
            playback: .playing(session),
            narrationPosition: position(0.4)
        )

        #expect(reconciler.reconcile(state).isEmpty)
    }

    @Test("a paused controller target still navigates and updates the narration resume anchor")
    func pausedTargetStillNavigatesAndSetsResumeAnchor() {
        var reconciler = SharedReadingStateReconciler()
        let target = position(0.7, href: "chapter-2.xhtml", page: 5)
        let state = input(
            desiredPosition: target,
            visiblePosition: position(0.4),
            narrationPosition: position(0.2),
            playback: .paused(UUID())
        )

        let effects = reconciler.reconcile(state)

        #expect(containsPositionEffect(effects, matching: target) {
            guard case let .navigateVisible(position, _) = $0 else { return nil }
            return position
        })
        #expect(containsPositionEffect(effects, matching: target) {
            guard case let .setPausedResumeAnchor(position, _) = $0 else { return nil }
            return position
        })
        #expect(!effects.contains { if case .pause = $0 { true } else { false } })
        #expect(!effects.contains { if case .startOrResume = $0 { true } else { false } })
        #expect(!effects.contains { if case .setRate = $0 { true } else { false } })
    }

    @Test("visible page agreement does not hide material narration drift")
    func materialNarrationDriftIsReconciledIndependently() {
        var reconciler = SharedReadingStateReconciler()
        let target = position(0.7, href: "chapter-2.xhtml", page: 5)
        let state = input(
            source: .readAloud,
            desiredPlayback: .playing,
            desiredPosition: target,
            visiblePosition: target,
            narrationPosition: position(0.2),
            playback: .playing(UUID())
        )

        let effects = reconciler.reconcile(state)

        #expect(containsPositionEffect(effects, matching: target) {
            guard case let .realignNarration(position, _) = $0 else { return nil }
            return position
        })
        #expect(!effects.contains { if case .navigateVisible = $0 { true } else { false } })
    }

    @Test("a reader-only page correction does not restart aligned narration")
    func visibleOnlyCorrectionDoesNotRestartNarration() {
        var reconciler = SharedReadingStateReconciler()
        let target = position(0.7, href: "chapter-2.xhtml", page: 5)
        let narration = position(0.4)
        let state = input(
            desiredPosition: target,
            visiblePosition: position(0.4),
            narrationPosition: narration,
            desiredPlayback: .playing,
            playback: .playing(UUID())
        )

        let effects = reconciler.reconcile(state)

        #expect(containsPositionEffect(effects, matching: target) {
            guard case let .navigateVisible(position, _) = $0 else { return nil }
            return position
        })
        #expect(!effects.contains { if case .realignNarration = $0 { true } else { false } })
        #expect(!effects.contains { if case .startOrResume = $0 { true } else { false } })
    }

    @Test("minor read-aloud cursor drift does not restart narration")
    func minorReadAloudDriftDoesNotRestart() {
        var reconciler = SharedReadingStateReconciler()
        let target = position(0.4)
        let state = input(
            source: .readAloud,
            desiredPlayback: .playing,
            desiredPosition: target,
            narrationPosition: position(0.401),
            playback: .playing(UUID())
        )

        let effects = reconciler.reconcile(state)

        #expect(!effects.contains { if case .realignNarration = $0 { true } else { false } })
        #expect(!effects.contains { if case .startOrResume = $0 { true } else { false } })
    }

    @Test("a completion from a superseded authority revision is rejected")
    func staleCompletionIsRejectedAfterNewerProgress() throws {
        var reconciler = SharedReadingStateReconciler()
        let firstInput = input(desiredPosition: position(0.7), visiblePosition: position(0.4))
        let oldEffect = #require(reconciler.reconcile(firstInput).first)
        let newerInput = input(sequence: 2, desiredPosition: position(0.8), visiblePosition: position(0.4))
        _ = reconciler.reconcile(newerInput)

        #expect(!reconciler.complete(oldEffect, succeeded: true, observation: matchingObservation(for: newerInput)))
    }

    @Test("failed effects can be retried after a meaningful observation change")
    func failedEffectRetriesAfterObservationChanges() throws {
        var reconciler = SharedReadingStateReconciler()
        let initial = input(desiredPosition: position(0.7), visiblePosition: position(0.4))
        let effect = #require(reconciler.reconcile(initial).first)
        #expect(!reconciler.complete(effect, succeeded: false, observation: matchingObservation(for: initial)))

        // A repeated sample does not spin; a later changed sample permits a fresh attempt.
        #expect(reconciler.reconcile(initial).isEmpty)
        let later = input(desiredPosition: position(0.7), visiblePosition: position(0.45))
        let retry = reconciler.reconcile(later)

        #expect(containsPositionEffect(retry, matching: position(0.7)) {
            guard case let .navigateVisible(position, _) = $0 else { return nil }
            return position
        })
    }

    @Test("accepted navigation waits for observation change, retries mismatch, and settles at the target")
    func acceptedNavigationWaitsForObservedPosition() throws {
        var reconciler = SharedReadingStateReconciler()
        let target = position(0.7)
        let initial = input(
            desiredPosition: target,
            visiblePosition: position(0.4),
            narrationPosition: target
        )
        let acceptedNavigation = try #require(reconciler.reconcile(initial).first { effect in
            if case .navigateVisible = effect { true } else { false }
        })

        #expect(reconciler.deferAcceptedNavigation(
            acceptedNavigation,
            observedPosition: initial.visiblePosition
        ))
        #expect(!reconciler.reconcile(initial).contains { if case .navigateVisible = $0 { true } else { false } })

        let changedButStillMismatched = input(
            desiredPosition: target,
            visiblePosition: position(0.45),
            narrationPosition: target
        )
        let retry = try #require(reconciler.reconcile(changedButStillMismatched).first { effect in
            if case .navigateVisible = effect { true } else { false }
        })
        #expect(retry.revision == acceptedNavigation.revision)
        #expect(reconciler.deferAcceptedNavigation(
            retry,
            observedPosition: changedButStillMismatched.visiblePosition
        ))

        let matching = input(
            desiredPosition: target,
            visiblePosition: target,
            narrationPosition: target
        )
        #expect(!reconciler.reconcile(matching).contains { if case .navigateVisible = $0 { true } else { false } })
        #expect(reconciler.reconcile(matching).isEmpty)
    }

    @Test("a reader-only target never realigns active narration")
    func readerTargetDoesNotRealignActiveNarration() {
        var reconciler = SharedReadingStateReconciler()
        let state = input(
            desiredPosition: position(0.7, href: "chapter-2.xhtml", page: 5),
            desiredPlayback: .playing,
            visiblePosition: position(0.4),
            narrationPosition: position(0.2),
            playback: .playing(UUID())
        )

        let effects = reconciler.reconcile(state)

        #expect(effects.contains { if case .navigateVisible = $0 { true } else { false } })
        #expect(!effects.contains { if case .realignNarration = $0 { true } else { false } })
    }

    @Test("a changed input clears failed suppression even when it has no effects")
    func convergedInputClearsFailedEffectSuppression() throws {
        var reconciler = SharedReadingStateReconciler()
        let initial = input(desiredPosition: position(0.7), visiblePosition: position(0.4))
        let failed = #require(reconciler.reconcile(initial).first)
        #expect(!reconciler.complete(failed, succeeded: false, observation: matchingObservation(for: initial)))
        #expect(reconciler.reconcile(initial).isEmpty)

        let converged = input(
            desiredPosition: position(0.4),
            visiblePosition: position(0.4),
            narrationPosition: position(0.4)
        )
        #expect(reconciler.reconcile(converged).isEmpty)

        let regressed = reconciler.reconcile(initial)
        #expect(containsPositionEffect(regressed, matching: position(0.7)) {
            guard case let .navigateVisible(position, _) = $0 else { return nil }
            return position
        })
    }

    @Test("a newer playback revision invalidates an in-flight narration realignment")
    func newerPlaybackRevisionRejectsRealignmentCompletion() throws {
        var reconciler = SharedReadingStateReconciler()
        let active = input(
            source: .readAloud,
            desiredPlayback: .playing,
            desiredPosition: position(0.7),
            narrationPosition: position(0.2),
            playback: .playing(UUID())
        )
        let realignment = try #require(reconciler.reconcile(active).first { effect in
            if case .realignNarration = effect { true } else { false }
        })
        let newer = input(
            source: .readAloud,
            desiredPlayback: .paused,
            desiredPosition: position(0.7),
            narrationPosition: position(0.2),
            playback: .playing(UUID())
        )
        _ = reconciler.reconcile(newer)

        #expect(!reconciler.complete(realignment, succeeded: true, observation: matchingObservation(for: newer)))
    }

    @Test("a newer rate authority invalidates an in-flight narration realignment")
    func newerRateAuthorityRejectsRealignmentCompletion() throws {
        var reconciler = SharedReadingStateReconciler()
        let active = input(
            source: .readAloud,
            desiredPlayback: .playing,
            desiredPosition: position(0.7),
            narrationPosition: position(0.2),
            playback: .playing(UUID())
        )
        let realignment = try #require(reconciler.reconcile(active).first { effect in
            if case .realignNarration = effect { true } else { false }
        })
        let newer = SharedReadingReconcileInput(
            authority: authority(sequence: 2),
            desiredPosition: active.desiredPosition,
            desiredPlayback: active.desiredPlayback,
            desiredRate: 1.5,
            visiblePosition: active.visiblePosition,
            narrationPosition: active.narrationPosition,
            playback: active.playback,
            effectiveRate: active.effectiveRate
        )
        _ = reconciler.reconcile(newer)

        #expect(!reconciler.complete(realignment, succeeded: true, observation: matchingObservation(for: newer)))
    }

    @Test("a combined rate and cursor correction uses the newest narration target")
    func combinedRateAndCursorCorrectionUsesLatestTarget() throws {
        var reconciler = SharedReadingStateReconciler()
        let older = input(
            sequence: 1,
            source: .readAloud,
            desiredPlayback: .playing,
            desiredPosition: position(0.6),
            narrationPosition: position(0.2),
            playback: .playing(UUID()),
            effectiveRate: 1
        )
        _ = reconciler.reconcile(older)

        let latestTarget = position(0.8, href: "chapter-2.xhtml", page: 5)
        let latest = input(
            sequence: 2,
            source: .readAloud,
            desiredPlayback: .playing,
            desiredPosition: latestTarget,
            narrationPosition: position(0.2),
            playback: .playing(UUID()),
            desiredRate: 1.5,
            effectiveRate: 1
        )
        let effects = reconciler.reconcile(latest)
        let realignment = try #require(effects.first { effect in
            if case .realignNarration = effect { true } else { false }
        })
        let rate = try #require(effects.first { effect in
            if case .setRate = effect { true } else { false }
        })

        guard case let .realignNarration(cursor, cursorRevision) = realignment,
              case let .setRate(_, rateRevision) = rate else {
            Issue.record("Expected narration and rate effects")
            return
        }
        #expect(cursor == latestTarget)
        #expect(cursorRevision == rateRevision)
    }

    @Test("playing alone does not confirm a start with an unknown or mismatched narration cursor")
    func startRequiresMatchingNarrationCursorObservation() throws {
        let target = position(0.7, href: "chapter-2.xhtml", page: 5)
        let unknownInput = input(
            desiredPosition: target,
            desiredPlayback: .playing,
            visiblePosition: target,
            narrationPosition: nil,
            playback: .noSession
        )
        var unknownReconciler = SharedReadingStateReconciler()
        let unknownStart = try #require(unknownReconciler.reconcile(unknownInput).first { effect in
            if case .startOrResume = effect { true } else { false }
        })
        let unknownCursorObservation = SharedReadingLocalObservation(
            visiblePosition: target,
            narrationPosition: nil,
            playback: .playing(UUID()),
            effectiveRate: unknownInput.effectiveRate
        )
        #expect(!unknownReconciler.complete(unknownStart, succeeded: true, observation: unknownCursorObservation))

        let mismatchedInput = input(
            desiredPosition: target,
            desiredPlayback: .playing,
            visiblePosition: target,
            narrationPosition: position(0.2),
            playback: .paused(UUID())
        )
        var mismatchedReconciler = SharedReadingStateReconciler()
        let mismatchedStart = try #require(mismatchedReconciler.reconcile(mismatchedInput).first { effect in
            if case .startOrResume = effect { true } else { false }
        })
        let mismatchedCursorObservation = SharedReadingLocalObservation(
            visiblePosition: target,
            narrationPosition: position(0.2),
            playback: .playing(UUID()),
            effectiveRate: mismatchedInput.effectiveRate
        )
        #expect(!mismatchedReconciler.complete(mismatchedStart, succeeded: true, observation: mismatchedCursorObservation))
    }

    @Test("an unrelated rate observation change preserves pending visible navigation")
    func rateObservationChangePreservesPendingNavigation() throws {
        var reconciler = SharedReadingStateReconciler()
        let target = position(0.7, href: "chapter-2.xhtml", page: 5)
        let initial = input(
            desiredPosition: target,
            visiblePosition: position(0.4),
            effectiveRate: 1
        )
        let navigation = try #require(reconciler.reconcile(initial).first { effect in
            if case .navigateVisible = effect { true } else { false }
        })

        let changedRateObservation = input(
            desiredPosition: target,
            visiblePosition: position(0.4),
            effectiveRate: 1.1
        )
        let effects = reconciler.reconcile(changedRateObservation)
        #expect(!effects.contains { if case .navigateVisible = $0 { true } else { false } })

        let confirmed = SharedReadingLocalObservation(
            visiblePosition: target,
            narrationPosition: changedRateObservation.narrationPosition,
            playback: changedRateObservation.playback,
            effectiveRate: changedRateObservation.effectiveRate
        )
        #expect(reconciler.complete(navigation, succeeded: true, observation: confirmed))

        let converged = input(
            desiredPosition: target,
            visiblePosition: target,
            effectiveRate: 1.1
        )
        #expect(!reconciler.reconcile(converged).contains { if case .navigateVisible = $0 { true } else { false } })
    }
}
