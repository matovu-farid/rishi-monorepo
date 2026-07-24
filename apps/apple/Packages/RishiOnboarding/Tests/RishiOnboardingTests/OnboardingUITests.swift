import Testing
import Foundation
import SwiftUI
@testable import RishiOnboarding

@MainActor
@Suite("Onboarding UI construction smoke")
struct OnboardingUITests {

    @Test("WelcomeScreen constructs")
    func welcomeConstructs() {
        _ = WelcomeScreen(onGetStarted: {}, logo: "rishi").body
    }

    @Test("MicPermissionPrimer constructs")
    func micPrimerConstructs() {
        _ = MicPermissionPrimer(onAllow: {}, onSkip: {}).body
    }

    @Test("FirstReaderHint constructs")
    func hintConstructs() {
        _ = FirstReaderHint(onGotIt: {}).body
    }

    @Test("SampleOrImportScreen constructs")
    func sampleOrImportConstructs() {
        _ = SampleOrImportScreen(
            onUseSample: {},
            onImport: {},
            onSkip: {}
        ).body
    }

    @Test("VoiceLanguagePrimer constructs")
    func voiceLanguageConstructs() {
        _ = VoiceLanguagePrimer(
            selection: .constant("en"),
            onContinue: {},
            onSkip: {}
        ).body
    }

    @Test("OnboardingFlowView constructs for every stage")
    func flowConstructsForEveryStage() async {
        let stages: [OnboardingCoordinator.Stage] = [
            .welcome, .micPrimer,
            .voiceLanguagePrimer, .firstReaderHint, .completed
        ]
        for stage in stages {
            let coord = OnboardingCoordinator(state: InMemoryOnboardingState())
            coord.setStageForTest(stage)
            let view = OnboardingFlowView(
                coordinator: coord,
                onRequestMic: {},
                voiceLanguage: .constant("en"),
                onCompleted: {}
            )
            _ = view.body
        }
    }
}
