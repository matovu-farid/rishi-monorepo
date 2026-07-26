import Foundation
import Observation


/// First-run flow state machine driving the sequence:
/// welcome → micPrimer → voiceLanguagePrimer → firstReaderHint → completed.
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
        case micPrimer
        case voiceLanguagePrimer
        case firstReaderHint
        case completed
    }

    public internal(set) var currentStage: Stage = .welcome

    private let state: any OnboardingState

    public init(state: any OnboardingState) {
        self.state = state
    }

    /// Move to the next stage. Honors `state.primerShownMic` to skip the
    /// already-shown mic primer for returning users. Reaching `.completed`
    /// persists `hasCompletedOnboarding = true` so the flow never reappears
    /// on relaunch.
    public func advance() async {
        let next: Stage
        switch currentStage {
        case .welcome:
            // If we've already shown the mic primer once, skip past it.
            if await state.primerShownMic() {
                next = .voiceLanguagePrimer
            } else {
                next = .micPrimer
            }
        case .micPrimer:
            await state.setPrimerShownMic(true)
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
        let prev: Stage
        switch currentStage {
        case .welcome:              prev = .welcome
        case .micPrimer:            prev = .welcome
        case .voiceLanguagePrimer:   prev = .micPrimer
        case .firstReaderHint:      prev = .voiceLanguagePrimer
        case .completed:            prev = .firstReaderHint
        }
        currentStage = prev
    }

    /// Skip the current primer stage. Records that the primer was shown so we
    /// don't nag on relaunch, then advances to the next stage.
    public func skipCurrentStage() async {
        switch currentStage {
        case .micPrimer:
            await state.setPrimerShownMic(true)
            currentStage = .voiceLanguagePrimer
        case .voiceLanguagePrimer:
            currentStage = .firstReaderHint
        case .firstReaderHint:
            await state.setHasCompletedOnboarding(true)
            currentStage = .completed
        default:
            await advance()
        }
    }

    // MARK: - Test-only seam
    //
    // The test target uses `@testable import RishiOnboarding` to reach this
    // internal setter. Production callers see `currentStage` as read-only.
    func setStageForTest(_ stage: Stage) {
        currentStage = stage
    }
}
