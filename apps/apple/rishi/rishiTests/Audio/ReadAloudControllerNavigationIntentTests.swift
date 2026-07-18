import Foundation
import RishiAudio
import RishiCore
import Testing
@testable import rishi

@Suite("ReadAloudController navigation intent")
@MainActor
struct ReadAloudControllerNavigationIntentTests {

    private func makeControllerForNavIntent() -> ReadAloudController {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: .holds)
        let settingsStore = InMemoryTTSSettingsStore()
        let prewarmer = TTSPrewarmer(source: NavIntentNoopChunkSource())
        let configurer = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurer)
        let presence = rishi.TTSPresenceController(
            state: state,
            store: NavIntentNoopPresenceStore()
        )
        return ReadAloudController(
            ttsEngine: engine,
            ttsState: state,
            ttsSettingsStore: settingsStore,
            ttsPrewarmer: prewarmer,
            ttsPresence: presence,
            coordidator: coordinator,
            userId: UserID()
        )
    }

    @Test("first matching nav continues and consumes credit; second stops")
    func followCreditConsumedOnce() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken, page: nil)

        let snap1 = controller.beginUserNavigationIntent()
        let first = controller.resolveUserNavigationIntent(
            snapshot: snap1,
            destinationParagraphs: [spoken],
            destinationPage: nil
        )
        #expect(first == .continuePlaying(consumesFollowCredit: true))

        let snap2 = controller.beginUserNavigationIntent()
        let second = controller.resolveUserNavigationIntent(
            snapshot: snap2,
            destinationParagraphs: [spoken],
            destinationPage: nil
        )
        #expect(second == .stopPlaying)
    }

    @Test("stale generation returns nil and does not consume credit")
    func staleGenerationIgnored() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken, page: nil)

        let stale = controller.beginUserNavigationIntent()
        _ = controller.beginUserNavigationIntent() // newer wins

        let result = controller.resolveUserNavigationIntent(
            snapshot: stale,
            destinationParagraphs: [spoken],
            destinationPage: nil
        )
        #expect(result == nil)

        let fresh = controller.beginUserNavigationIntent()
        let continued = controller.resolveUserNavigationIntent(
            snapshot: fresh,
            destinationParagraphs: [spoken],
            destinationPage: nil
        )
        #expect(continued == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("same utterance text does not refill credit; new text does")
    func creditRefillsOnlyOnNewUtteranceText() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken)

        let snap1 = controller.beginUserNavigationIntent()
        #expect(
            controller.resolveUserNavigationIntent(
                snapshot: snap1,
                destinationParagraphs: [spoken],
                destinationPage: nil
            ) == .continuePlaying(consumesFollowCredit: true)
        )

        controller.notifyUtterancePlayingForTests(text: spoken)
        let snap2 = controller.beginUserNavigationIntent()
        #expect(
            controller.resolveUserNavigationIntent(
                snapshot: snap2,
                destinationParagraphs: [spoken],
                destinationPage: nil
            ) == .stopPlaying
        )

        let next = spoken + " next"
        controller.notifyUtterancePlayingForTests(text: next)
        let snap3 = controller.beginUserNavigationIntent()
        #expect(
            controller.resolveUserNavigationIntent(
                snapshot: snap3,
                destinationParagraphs: [next],
                destinationPage: nil
            ) == .continuePlaying(consumesFollowCredit: true)
        )
    }

    @Test("resolve uses snapshotted spoken paragraph, not a later live update")
    func resolveUsesSnapshotNotLiveParagraph() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken)

        let snapshot = controller.beginUserNavigationIntent()
        // Simulate utterance advancing during extract.
        controller.notifyUtterancePlayingForTests(text: spoken + " advanced")

        let intent = controller.resolveUserNavigationIntent(
            snapshot: snapshot,
            destinationParagraphs: [spoken],
            destinationPage: nil
        )
        #expect(intent == .continuePlaying(consumesFollowCredit: true))
    }

    @Test("continue on old spoken after advance does not steal new utterance credit")
    func continueOnStaleSpokenDoesNotStealNewCredit() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        let next = spoken + " advanced"
        controller.simulateSpeakingForTests(paragraph: spoken)

        let snapshot = controller.beginUserNavigationIntent()
        controller.notifyUtterancePlayingForTests(text: next)

        #expect(
            controller.resolveUserNavigationIntent(
                snapshot: snapshot,
                destinationParagraphs: [spoken],
                destinationPage: nil
            ) == .continuePlaying(consumesFollowCredit: true)
        )

        // New utterance still has its refilled follow credit.
        let fresh = controller.beginUserNavigationIntent()
        #expect(
            controller.resolveUserNavigationIntent(
                snapshot: fresh,
                destinationParagraphs: [next],
                destinationPage: nil
            ) == .continuePlaying(consumesFollowCredit: true)
        )
    }

    @Test("PDF page on spoken locator is snapshotted for same-page continue")
    func pdfSamePageViaSimulatedLocator() {
        let controller = makeControllerForNavIntent()
        let spoken = String(repeating: "Cross page paragraph text for credit. ", count: 3)
        controller.simulateSpeakingForTests(paragraph: spoken, page: 4)

        let snapshot = controller.beginUserNavigationIntent()
        #expect(snapshot.spokenPage == 4)
        let intent = controller.resolveUserNavigationIntent(
            snapshot: snapshot,
            destinationParagraphs: ["other"],
            destinationPage: 4
        )
        #expect(intent == .continuePlaying(consumesFollowCredit: false))
    }
}

private struct NavIntentNoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class NavIntentNoopPresenceStore: TTSPresenceStore, @unchecked Sendable {
    func read() -> TTSPresenceSnapshot? { nil }
    func write(_ snapshot: TTSPresenceSnapshot) {}
    func clear() {}
}
