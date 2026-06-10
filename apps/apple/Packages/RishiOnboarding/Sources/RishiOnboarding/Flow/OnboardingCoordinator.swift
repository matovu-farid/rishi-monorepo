import Foundation
import Observation
import RishiLogging

/// First-run flow state machine driving the sequence:
/// welcome → signIn → sampleOrImport → micPrimer → notificationsPrimer →
/// firstReaderHint → completed.
///
/// Each stage's user-facing button is wired to a closure in 11-06. The
/// coordinator only owns the stage transitions and the persisted flag updates
/// (mic/notifications primer shown, hasCompletedOnboarding).
///
/// `currentStage` is `public internal(set)` so the test target can pin the
/// machine to an arbitrary stage via `setStageForTest(...)` without walking
/// the whole sequence.
@MainActor
@Observable
public final class OnboardingCoordinator {

    public enum Stage: String, Sendable, Equatable {
        case welcome
        case signIn
        case sampleOrImport
        case micPrimer
        case notificationsPrimer
        case firstReaderHint
        case completed
    }

    public internal(set) var currentStage: Stage = .welcome

    private let state: any OnboardingState

    public init(state: any OnboardingState) {
        self.state = state
    }

    /// Move to the next stage. Honors `state.primerShownMic` /
    /// `state.primerShownNotifications` to skip already-shown primers
    /// (returning user). Reaching `.completed` persists
    /// `hasCompletedOnboarding = true` so the flow never reappears on relaunch.
    public func advance() async {
        let next: Stage
        switch currentStage {
        case .welcome:
            next = .signIn
        case .signIn:
            next = .sampleOrImport
        case .sampleOrImport:
            // If we've already shown the mic primer once, skip past it.
            if await state.primerShownMic() {
                next = (await state.primerShownNotifications()) ? .firstReaderHint : .notificationsPrimer
            } else {
                next = .micPrimer
            }
        case .micPrimer:
            await state.setPrimerShownMic(true)
            next = (await state.primerShownNotifications()) ? .firstReaderHint : .notificationsPrimer
        case .notificationsPrimer:
            await state.setPrimerShownNotifications(true)
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
        case .signIn:               prev = .welcome
        case .sampleOrImport:       prev = .signIn
        case .micPrimer:            prev = .sampleOrImport
        case .notificationsPrimer:  prev = .micPrimer
        case .firstReaderHint:      prev = .notificationsPrimer
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
            currentStage = .notificationsPrimer
        case .notificationsPrimer:
            await state.setPrimerShownNotifications(true)
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
