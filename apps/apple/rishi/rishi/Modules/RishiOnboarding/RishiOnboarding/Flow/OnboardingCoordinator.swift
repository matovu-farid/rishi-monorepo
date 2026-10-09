import Foundation
import Observation


/// First-run flow state machine driving the sequence:
/// welcome → voiceLanguagePrimer → firstReaderHint → completed.
///
/// Each stage's user-facing button is wired to a closure in 11-06. The
/// coordinator only owns the stage transitions and the persisted flag updates
/// (mic primer shown, hasCompletedOnboarding).
///
/// `currentStage` is `public internal(set)` so the test target can pin the
/// machine to an arbitrary stage via `setStageForTest(...)` without walking
/// the whole sequence.
@MainActor
@Observable
public final class OnboardingCoordinator {

    public enum Stage: String, Sendable, Equatable {
        case welcome
        case voiceLanguagePrimer
        case firstReaderHint
        case completed
    }

    public internal(set) var currentStage: Stage = .welcome

    private(set) var isTransitioning = false

    private let state: any OnboardingState

    public init(state: any OnboardingState) {
        self.state = state
    }

    func beginTransition() -> Bool {
        guard !isTransitioning else { return false }
        isTransitioning = true
        return true
    }

    func endTransition() {
        isTransitioning = false
    }

    /// Move to the next stage. Honors `state.primerShownMic` to skip the
    /// already-shown mic primer for returning users. Reaching `.completed`
    /// persists `hasCompletedOnboarding = true` so the flow never reappears
    /// on relaunch.
    public func advance() async {
        let next: Stage
        switch currentStage {
        case .welcome:
            // Microphone permission is intentionally deferred until a signed-in
            // user has accepted the combined data-use consent.
            next = .voiceLanguagePrimer
        case .voiceLanguagePrimer:
            next = .firstReaderHint
        case .firstReaderHint:
            await state.setHasCompletedOnboarding(true)
            Log.event("onboarding.completed", level: .info, data: [:])
            next = .completed
        case .completed:
            next = .completed
        }
        currentStage = next
    }

    /// Move back one stage. Clamped at `.welcome`.
    public func back() {
        guard !isTransitioning else { return }
        let prev: Stage
        switch currentStage {
        case .welcome:              prev = .welcome
        case .voiceLanguagePrimer:   prev = .welcome
        case .firstReaderHint:      prev = .voiceLanguagePrimer
        case .completed:            prev = .firstReaderHint
        }
        currentStage = prev
    }

    // MARK: - Test-only seam
    //
    // The test target uses `@testable import RishiOnboarding` to reach this
    // internal setter. Production callers see `currentStage` as read-only.
    func setStageForTest(_ stage: Stage) {
        currentStage = stage
    }
}
