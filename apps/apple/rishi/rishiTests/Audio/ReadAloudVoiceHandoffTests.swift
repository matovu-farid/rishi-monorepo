import Foundation


import Testing
@testable import rishi

@Suite("ReadAloud voice handoff")
@MainActor
struct ReadAloudVoiceHandoffTests {

    private let testBookID = "test-book"
    private let testMetadata = NowPlayingMetadata(title: "Test Book")

    private func makeController(
        script: FakeTTSEngine.Script = .holds
    ) -> (ReadAloudController, TTSPlaybackState) {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state, script: script)
        let settingsStore = InMemoryTTSSettingsStore()
        let prewarmer = TTSPrewarmer(source: HandoffNoopChunkSource())
        let configurer = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurer)
        let presence = rishi.TTSPresenceController(
            state: state,
            store: HandoffNoopPresenceStore()
        )
        let controller = ReadAloudController(
            ttsEngine: engine,
            ttsState: state,
            ttsSettingsStore: settingsStore,
            ttsPrewarmer: prewarmer,
            ttsPresence: presence,
            coordidator: coordinator,
            userId: UserID()
        )
        return (controller, state)
    }

    @Test("pauseForVoiceHandoff pauses playing session and sets wantsAutoResume")
    func pausePlayingSetsFlag() async {
        let (controller, state) = makeController()
        await controller.start(
            paragraphs: ["alpha"],
            bookID: testBookID,
            metadata: testMetadata,
            onPassageChange: { _ in }
        )
        #expect(state.status == .playing)

        await controller.pauseForVoiceHandoff()

        #expect(controller.wantsAutoResumeAfterVoice)
        #expect(state.status == .paused)
        await controller.stop()
    }

    @Test("pauseForVoiceHandoff when idle does not set wantsAutoResume")
    func idleHandoffNoFlag() async {
        let (controller, _) = makeController()
        #expect(controller.showControls == false)

        await controller.pauseForVoiceHandoff()

        #expect(controller.wantsAutoResumeAfterVoice == false)
    }

    @Test("resumeAfterVoiceIfNeeded resumes only when flag set")
    func resumeWhenFlagged() async {
        let (controller, state) = makeController()
        await controller.start(
            paragraphs: ["alpha"],
            bookID: testBookID,
            metadata: testMetadata,
            onPassageChange: { _ in }
        )
        await controller.pauseForVoiceHandoff()
        #expect(state.status == .paused)

        await controller.resumeAfterVoiceIfNeeded()

        #expect(controller.wantsAutoResumeAfterVoice == false)
        #expect(state.status == .playing)
        await controller.stop()
    }

    @Test("manual pause during voice clears wantsAutoResume")
    func manualPauseClearsFlag() async {
        let (controller, state) = makeController()
        await controller.start(
            paragraphs: ["alpha"],
            bookID: testBookID,
            metadata: testMetadata,
            onPassageChange: { _ in }
        )
        await controller.pauseForVoiceHandoff()
        #expect(controller.wantsAutoResumeAfterVoice)

        await controller.togglePlayback()
        #expect(state.status == .playing)

        await controller.togglePlayback()

        #expect(controller.wantsAutoResumeAfterVoice == false)
        #expect(state.status == .paused)
        await controller.stop()
    }
}

private struct HandoffNoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) async -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private final class HandoffNoopPresenceStore: TTSPresenceStore, @unchecked Sendable {
    func read() -> TTSPresenceSnapshot? { nil }
    func write(_ snapshot: TTSPresenceSnapshot) {}
    func clear() {}
}
