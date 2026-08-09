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

    @Test("SampleOrImportScreen makes personal import the primary action")
    func sampleOrImportMakesImportPrimary() throws {
        let source = try String(
            contentsOf: Self.rishiRoot()
                .appendingPathComponent("rishi/Modules/RishiOnboarding/RishiOnboarding/UI/SampleOrImportScreen.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Text(\"Import your book\")"))
        #expect(source.contains("Text(\"Use a sample book\")"))
        let importIndex = try #require(source.range(of: "Button(action: onImport)")?.lowerBound)
        let sampleIndex = try #require(source.range(of: "Button(action: onUseSample)")?.lowerBound)
        #expect(importIndex < sampleIndex)
    }

    @Test("Reader destination recreates its guided subtree after request resolution")
    func readerDestinationRecreatesGuidedSubtree() throws {
        let source = try String(
            contentsOf: Self.rishiRoot()
                .appendingPathComponent("rishi/Reader/ReaderDestinationView.swift"),
            encoding: .utf8
        )

        #expect(source.contains(".id(startReaderTour)"))
    }

    @Test("Prompt-originated multi-import chooses the first eligible reading format")
    func multiImportKeepsGuidedBookEligible() throws {
        let source = try String(
            contentsOf: Self.rishiRoot()
                .appendingPathComponent("rishi/Library/LibraryTabView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("successes.first(where:"))
        #expect(source.contains("book.formatType == .epub || book.formatType == .pdf"))
    }

    @Test("Sign-out ends voice before account state is cleared")
    func signOutEndsVoiceSession() throws {
        let source = try String(
            contentsOf: Self.rishiRoot()
                .appendingPathComponent("rishi/RootView.swift"),
            encoding: .utf8
        )

        let endIndex = try #require(source.range(of: "await deps.services?.voice.presenter.requestEnd()")?.lowerBound)
        let signOutIndex = try #require(source.range(of: "await deps.performSignOut(currentUserBox: currentUserBox)")?.lowerBound)
        #expect(endIndex < signOutIndex)
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
