@testable import rishi
import Testing
import Foundation
import SwiftUI


@MainActor
@Suite("Onboarding UI construction smoke")
struct OnboardingUITests {

    private static func rishiRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RishiOnboardingTests
            .deletingLastPathComponent() // RishiOnboarding
            .deletingLastPathComponent() // PackageTests
            .deletingLastPathComponent() // rishiTests
            .deletingLastPathComponent() // rishi
    }

    @Test("Microphone primer uses neutral Continue wording")
    func micPermissionPrimerUsesContinue() throws {
        let source = try String(
            contentsOf: Self.rishiRoot()
                .appendingPathComponent("rishi/Modules/RishiOnboarding/RishiOnboarding/UI/MicPermissionPrimer.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Text(\"Continue\")"))
        #expect(!source.contains("Allow microphone"))
        #expect(source.contains("Button(\"Not now\", action: onSkip)"))
    }

    @Test("Background modes match the supported audio and sync features")
    func backgroundModesMatchSupportedFeatures() throws {
        let data = try Data(
            contentsOf: Self.rishiRoot().appendingPathComponent("rishi/Info.plist")
        )
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        let dictionary = try #require(propertyList as? [String: Any])
        let modes = try #require(dictionary["UIBackgroundModes"] as? [String])

        #expect(Set(modes) == Set(["audio", "processing"]))
    }

    @Test("Onboarding CTA stays full width in compact layouts")
    func onboardingCTAUsesFullWidthInCompactLayouts() {
        #expect(OnboardingCTAConfiguration.maxWidth(for: .compact) == .infinity)
        #expect(OnboardingCTAConfiguration.maxWidth(for: nil) == .infinity)
    }

    @Test("Onboarding CTA is capped in regular layouts")
    func onboardingCTAUsesCompactWidthInRegularLayouts() {
        #expect(OnboardingCTAConfiguration.maxWidth(for: .regular) == 400)
    }

    @Test("Language primer copy is capped in regular layouts")
    func languagePrimerCopyUsesReadableWidthInRegularLayouts() {
        #expect(OnboardingContentConfiguration.maxWidth(for: .regular) == 560)
        #expect(OnboardingContentConfiguration.maxWidth(for: .compact) == .infinity)
    }

    @Test("WelcomeScreen constructs")
    func welcomeConstructs() {
        _ = WelcomeScreen(onGetStarted: {}, logo: "rishi").body
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
            .welcome,
            .voiceLanguagePrimer, .firstReaderHint, .completed
        ]
        for stage in stages {
            let coord = OnboardingCoordinator(state: InMemoryOnboardingState())
            coord.setStageForTest(stage)
            let view = OnboardingFlowView(
                coordinator: coord,
                voiceLanguage: .constant("en"),
                onCompleted: {}
            )
            _ = view.body
        }
    }
}
