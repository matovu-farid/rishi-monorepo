import Testing
import Foundation
@testable import RishiVoice
@testable import RishiAudio
import RishiCore
import RishiCore

/// Verifies the single-audio-owner invariant from the voice side: when
/// read-aloud (TTS) asks the SHARED `AudioSessionCoordinator` for `.tts`
/// while a voice session is live, the coordinator must run the voice
/// session's registered preempt handler — fully ending the session — before
/// granting `.tts`. Reuses the same fakes as `RealtimeVoiceSessionTests`
/// (`FakeRealtimeClient` disconnect spy, `FakeMicPermissionGate` granted,
/// `StubEphemeralKeyFetcher` success).
@MainActor
@Suite("RealtimeVoiceSession preemption", .serialized)
struct RealtimeVoiceSessionPreemptionTests {

    @Test("a tts mode request while voice is live ends the session")
    func ttsRequestEndsVoice() async {
        // GIVEN a granted mic + key-fetch success + connectable client, all
        // sharing ONE coordinator (mirrors RealtimeVoiceSessionTests.makeSession).
        let state = VoiceSessionState()
        let configurator = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let client = FakeRealtimeClient()
        let micGate = FakeMicPermissionGate(decision: .granted)
        let fetcher = StubEphemeralKeyFetcher(result: .success(.init(secret: "k", sessionId: "s")))

        let session = RealtimeVoiceSession(
            micGate: micGate,
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: client,
            state: state,
            backoff: { _ in .zero },
            maxReconnects: 3
        )
        // Production presenter owns preempt → requestEnd; package tests
        // register the local end() handler explicitly.
        await coordinator.registerPreemption(for: .voice) {
            _ = await session.end()
        }
        await session.start(language: "en")              // drives to .live
        #expect(state.status == .live)
        #expect(await coordinator.currentMode == .voice)

        // WHEN read-aloud asks the shared coordinator for .tts.
        await coordinator.requestActiveMode(.tts)

        // THEN the voice session ended (end() ran via the registered preempt):
        // the FakeRealtimeClient saw a disconnect and the mode is now .tts.
        #expect(client.disconnectCalls == 1)
        #expect(state.status == .ended)
        #expect(await coordinator.currentMode == .tts)
    }
}
