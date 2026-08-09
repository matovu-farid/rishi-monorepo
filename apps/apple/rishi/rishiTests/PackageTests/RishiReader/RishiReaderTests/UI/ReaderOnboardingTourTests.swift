@testable import rishi
import Foundation
import Testing

@Suite("Reader onboarding tour")
@MainActor
struct ReaderOnboardingTourTests {

    @Test("starts at read aloud and follows the ordered event contract")
    func orderedEventsAdvanceOneStepAtATime() {
        let tour = ReaderOnboardingTourCoordinator()

        #expect(tour.step == .readAloud)
        tour.readAloudTapped()
        #expect(tour.step == .waitingForReadAloud)
        tour.firstUtteranceFinished()
        #expect(tour.step == .swipe)
        tour.userNavigated()
        #expect(tour.step == .voiceChat)
        tour.voiceChatStarted()
        #expect(tour.step == .completed)
    }

    @Test("out-of-order and repeated events are no-ops")
    func invalidEventsDoNotAdvanceOrRegress() {
        let tour = ReaderOnboardingTourCoordinator()

        tour.firstUtteranceFinished()
        tour.userNavigated()
        tour.voiceChatStarted()
        #expect(tour.step == .readAloud)

        tour.readAloudTapped()
        tour.readAloudTapped()
        #expect(tour.step == .waitingForReadAloud)

        tour.userNavigated()
        tour.voiceChatStarted()
        #expect(tour.step == .waitingForReadAloud)

        tour.firstUtteranceFinished()
        tour.firstUtteranceFinished()
        #expect(tour.step == .swipe)

        tour.readAloudTapped()
        tour.voiceChatStarted()
        #expect(tour.step == .swipe)
    }

    @Test("read aloud failure returns to the actionable step")
    func readAloudFailureCanBeRetried() {
        let tour = ReaderOnboardingTourCoordinator()

        tour.readAloudTapped()
        tour.readAloudFailed()

        #expect(tour.step == .readAloud)
    }

    @Test("skip completes the tour from every active step")
    func skipCompletesFromEveryActiveStep() {
        let event: (ReaderOnboardingTourCoordinator) -> Void = { tour in tour.skip() }

        let initial = ReaderOnboardingTourCoordinator()
        event(initial)
        #expect(initial.step == .completed)

        let waiting = ReaderOnboardingTourCoordinator()
        waiting.readAloudTapped()
        event(waiting)
        #expect(waiting.step == .completed)

        let swipe = ReaderOnboardingTourCoordinator()
        swipe.readAloudTapped()
        swipe.firstUtteranceFinished()
        event(swipe)
        #expect(swipe.step == .completed)

        let voiceChat = ReaderOnboardingTourCoordinator()
        voiceChat.readAloudTapped()
        voiceChat.firstUtteranceFinished()
        voiceChat.userNavigated()
        event(voiceChat)
        #expect(voiceChat.step == .completed)
    }

    @Test("overlay keeps the one-step instruction and accessibility contract")
    func overlayContract() throws {
        let source = try String(contentsOf: Self.appRoot().appendingPathComponent("rishi/Reader/ReaderOnboardingTour.swift"), encoding: .utf8)

        #expect(source.contains("speaker.wave.2.fill"))
        #expect(source.contains("hand.draw.fill"))
        #expect(source.contains("waveform.circle.fill"))
        #expect(source.contains("Skip tour"))
        #expect(source.contains("reader-onboarding-tour"))
        #expect(source.contains("reader-onboarding-tour.instruction"))
        #expect(source.contains("reader-onboarding-tour.skip"))
        #expect(source.contains("allowsHitTesting(false)"))
    }

    private static func appRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != candidate.deletingLastPathComponent().path {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("rishi.xcodeproj").path) {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        fatalError("Could not locate rishi.xcodeproj above \(#filePath)")
    }
}
