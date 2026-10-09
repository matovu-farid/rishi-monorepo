@testable import rishi
import Foundation
import Testing

@Suite("Onboarding guidance policy")
@MainActor
struct OnboardingGuidancePolicyTests {

    @Test("ordinary reader tips remain eligible without a tour")
    func nilTourRestoresReaderTips() {
        #expect(!ReaderDestination.suppressesOnboardingTips(tourStep: nil))
        #expect(!OnboardingGuidancePolicy.suppressesReaderTips(isTourActive: false))
    }

    @Test("each active tour step suppresses reader tips")
    func activeTourStepsSuppressReaderTips() {
        let tour = ReaderOnboardingTourCoordinator()
        #expect(ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))

        tour.readAloudTapped()
        #expect(ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))

        tour.firstUtteranceFinished()
        #expect(ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))

        tour.userNavigated()
        #expect(ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))

        tour.voiceChatStarted()
        #expect(tour.step == .completed)
        #expect(!ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))
    }

    @Test("Skip restores reader tips from every active step")
    func skipRestoresReaderTips() {
        for activeStep in 0..<4 {
            let tour = ReaderOnboardingTourCoordinator()
            if activeStep >= 1 { tour.readAloudTapped() }
            if activeStep >= 2 { tour.firstUtteranceFinished() }
            if activeStep >= 3 { tour.userNavigated() }

            #expect(ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))
            tour.skip()
            #expect(tour.step == .completed)
            #expect(!ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))
        }
    }

    @Test("audio failure returns to a suppressed actionable tour step")
    func audioFailureKeepsReaderTipsSuppressed() {
        let tour = ReaderOnboardingTourCoordinator()
        tour.readAloudTapped()
        tour.readAloudFailed()

        #expect(tour.step == .readAloud)
        #expect(ReaderDestination.suppressesOnboardingTips(tourStep: tour.step))
    }

    @Test("import tip suppression combines live guidance and persisted recovery")
    func importPolicyTruthTable() {
        #expect(!OnboardingGuidancePolicy.suppressesImportTip(
            firstBookGuidanceActive: false,
            recoveryPending: false
        ))
        #expect(OnboardingGuidancePolicy.suppressesImportTip(
            firstBookGuidanceActive: true,
            recoveryPending: false
        ))
        #expect(OnboardingGuidancePolicy.suppressesImportTip(
            firstBookGuidanceActive: false,
            recoveryPending: true
        ))
        #expect(OnboardingGuidancePolicy.suppressesImportTip(
            firstBookGuidanceActive: true,
            recoveryPending: true
        ))
    }

    @Test("production first-book facts cover preparation, recovery, picker and acceptance waits")
    func firstBookGuidanceProductionFacts() {
        func active(
            promptVisible: Bool = false,
            pendingDismissalOrCompletion: Bool = false,
            pendingPresentation: Bool = false,
            recoveryReopen: Bool = false,
            samplePreparing: Bool = false,
            sampleReadyForHandoff: Bool = false,
            pickerQueuedOrVisible: Bool = false,
            ownedImportAwaitingAcceptance: Bool = false
        ) -> Bool {
            FirstBookImportGuidancePolicy.isActive(
                promptVisible: promptVisible,
                pendingDismissalOrCompletion: pendingDismissalOrCompletion,
                pendingPresentation: pendingPresentation,
                recoveryReopen: recoveryReopen,
                samplePreparing: samplePreparing,
                sampleReadyForHandoff: sampleReadyForHandoff,
                pickerQueuedOrVisible: pickerQueuedOrVisible,
                ownedImportAwaitingAcceptance: ownedImportAwaitingAcceptance
            )
        }

        #expect(active(promptVisible: true))
        #expect(active(pendingDismissalOrCompletion: true))
        #expect(active(pendingPresentation: true))
        #expect(active(recoveryReopen: true))
        #expect(active(samplePreparing: true))
        #expect(active(sampleReadyForHandoff: true))
        #expect(active(pickerQueuedOrVisible: true))
        #expect(active(ownedImportAwaitingAcceptance: true))
        #expect(!active())
    }
}
