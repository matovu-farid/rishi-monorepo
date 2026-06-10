import Testing
import Foundation
import SwiftUI
@testable import RishiOnboarding

@MainActor
@Suite("Onboarding UI construction smoke")
struct OnboardingUITests {

    @Test("WelcomeScreen constructs")
    func welcomeConstructs() {
        _ = WelcomeScreen(onGetStarted: {}).body
    }

    @Test("MicPermissionPrimer constructs")
    func micPrimerConstructs() {
        _ = MicPermissionPrimer(onAllow: {}, onSkip: {}).body
    }

    @Test("NotificationsPermissionPrimer constructs")
    func notifsPrimerConstructs() {
        _ = NotificationsPermissionPrimer(onAllow: {}, onSkip: {}).body
    }

    @Test("SampleOrImportScreen constructs")
    func sampleScreenConstructs() {
        _ = SampleOrImportScreen(onUseSample: {}, onImport: {}, onSkip: {}).body
    }

    @Test("FirstReaderHint constructs")
    func hintConstructs() {
        _ = FirstReaderHint(onGotIt: {}).body
    }

    @Test("OnboardingFlowView constructs for every stage")
    func flowConstructsForEveryStage() async {
        let stages: [OnboardingCoordinator.Stage] = [
            .welcome, .signIn, .sampleOrImport, .micPrimer,
            .notificationsPrimer, .firstReaderHint, .completed
        ]
        for stage in stages {
            let coord = OnboardingCoordinator(state: InMemoryOnboardingState())
            coord.setStageForTest(stage)
            let view = OnboardingFlowView(
                coordinator: coord,
                onSignIn: {},
                onUseSample: {},
                onImport: {},
                onRequestMic: {},
                onRequestNotifications: {},
                onCompleted: {}
            )
            _ = view.body
        }
    }
}
