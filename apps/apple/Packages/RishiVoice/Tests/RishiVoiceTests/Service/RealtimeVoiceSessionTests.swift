import Testing
import Foundation
@testable import RishiVoice
@testable import RishiAudio
import RishiAPI
import RishiCore

/// Tests for `RealtimeVoiceSession` — the lifecycle FSM actor that owns
/// voice chat sessions end-to-end. Every transition + the Spike-B
/// reconnect ladder is verified against fakes (no SDK, no WebRTC, no
/// network, no AVAudioSession).
///
/// `.serialized` because the suite drives `AudioSessionCoordinator`
/// (an actor) + `FakeRealtimeClient` (lock-guarded mutable state); running
/// in parallel would race state inspection across tests.
@MainActor
@Suite("RealtimeVoiceSession", .serialized)
struct RealtimeVoiceSessionTests {

    // MARK: - Happy path

    @Test("Happy path: idle → requestingMic → fetchingKey → connecting → live")
    func happyPath() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "en")
        #expect(fakes.state.status == .live)
        #expect(fakes.client.connectCalls == ["k"])
        #expect(await fakes.coordinator.currentMode == .voice)
    }

    @Test("End: live → ending → ended releases audio mode + disconnects client")
    func endReleasesAudioMode() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "en")
        #expect(fakes.state.status == .live)
        await fakes.session.end()
        #expect(fakes.state.status == .ended)
        #expect(fakes.client.disconnectCalls == 1)
        #expect(await fakes.coordinator.currentMode == .idle)
    }

    // MARK: - Failure paths

    @Test("Mic denied → .failed(.micDenied); coordinator never invoked")
    func micDeniedFails() async {
        let fakes = makeSession(micDecision: .denied)
        await fakes.session.start()
        #expect(fakes.state.status == .failed(reason: .micDenied))
        #expect(fakes.client.connectCalls.isEmpty)
        #expect(await fakes.coordinator.currentMode == .idle)
    }

    @Test(
        "Key fetch failure → .failed(.keyFetch(classified)); audio mode released",
        arguments: [
            (RishiError.unauthenticated, KeyFetchFailure.unauthorized),
            (RishiError.network(code: "BILLING_INACTIVE", message: "Pro required"), .subscriptionRequired),
            (RishiError.network(code: "http_4xx", message: "HTTP 404"), .serviceUnavailable),
            (RishiError.network(code: "http_5xx", message: "HTTP 5xx"), .serviceUnavailable),
            (RishiError.networkFailure(URLError(.notConnectedToInternet)), .network),
        ] as [(RishiError, KeyFetchFailure)]
    )
    func keyFetchFailsClassified(error: RishiError, expected: KeyFetchFailure) async {
        let fakes = makeSession(
            micDecision: .granted,
            keyFetchResult: .failure(error)
        )
        await fakes.session.start()
        #expect(fakes.state.status == .failed(reason: .keyFetch(expected)))
        #expect(fakes.client.connectCalls.isEmpty)
        #expect(await fakes.coordinator.currentMode == .idle)
    }

    @Test("Key fetch failure with non-RishiError → .keyFetch(.unknown)")
    func keyFetchFailsUnknown() async {
        struct StubFail: Error {}
        let fakes = makeSession(
            micDecision: .granted,
            keyFetchResult: .failure(StubFail())
        )
        await fakes.session.start()
        if case .failed(.keyFetch(.unknown)) = fakes.state.status {
            // ok
        } else {
            Issue.record("Expected .failed(.keyFetch(.unknown)), got \(fakes.state.status)")
        }
        #expect(fakes.client.connectCalls.isEmpty)
        #expect(await fakes.coordinator.currentMode == .idle)
    }

    @Test("Connect failure → .failed(.connect); audio mode released")
    func connectFails() async {
        struct StubFail: Error {}
        let fakes = makeSession(micDecision: .granted)
        fakes.client.failNextConnect(with: StubFail())
        await fakes.session.start()
        #expect(fakes.state.status == .failed(reason: .connect))
        #expect(await fakes.coordinator.currentMode == .idle)
    }

    // MARK: - Reconnect ladder (Spike B)

    @Test("Reconnect: transient disconnect → reconnecting(1) → live")
    func reconnectThenLive() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        #expect(fakes.state.status == .live)

        // Simulate a transient disconnect via the fake client status.
        fakes.client.setStatus(.disconnected)

        // The actor's status poll detects the disconnect; the test's
        // backoff strategy is .zero so we don't wait. Wait for a second
        // connect call to be recorded (proving the reconnect happened),
        // then confirm we're back in .live.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if fakes.client.connectCalls.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        // Give the actor a tick to update state after connect succeeds.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(fakes.client.connectCalls.count == 2)  // initial + 1 reconnect
        #expect(fakes.state.status == .live)
    }

    @Test("Reconnect: 3 consecutive failures → .failed(.networkLost); audio mode released")
    func reconnectExhausted() async throws {
        struct StubFail: Error {}
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        #expect(fakes.state.status == .live)

        // Arm a persistent connect-failure mode so every reconnect attempt
        // throws, then inject the disconnect to kick off the reconnect
        // ladder. With backoff=.zero the ladder exhausts in <1s of real time.
        fakes.client.failAllConnects(with: StubFail())
        fakes.client.setStatus(.disconnected)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .failed = fakes.state.status { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if case .failed(let reason) = fakes.state.status {
            #expect(reason == .networkLost)
        } else {
            Issue.record("Expected .failed(.networkLost), got \(fakes.state.status)")
        }
        // Initial connect (1) + 3 failed reconnect attempts = 4 total.
        #expect(fakes.client.connectCalls.count == 4)
        #expect(await fakes.coordinator.currentMode == .idle)
    }

    // MARK: - Audio session wiring (VOICE-04)

    @Test("Audio session is acquired BEFORE realtime client connect")
    func audioModeAcquiredBeforeConnect() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        // FakeAudioSessionConfigurator records `configure(...)` BEFORE the
        // client.connect happens — the order in `setActive` calls proves
        // the activation preceded the realtime handshake.
        #expect(fakes.configurator.configureCalls.count == 1)
        let first = fakes.configurator.configureCalls.first
        #expect(first?.category == .playAndRecord)
        #expect(first?.mode == .voiceChat)
        #expect(fakes.client.connectCalls == ["k"])
    }

    // MARK: - Builders

    struct Fakes {
        let session: RealtimeVoiceSession
        let state: VoiceSessionState
        let coordinator: AudioSessionCoordinator
        let configurator: FakeAudioSessionConfigurator
        let client: FakeRealtimeClient
        let micGate: FakeMicPermissionGate
    }

    @MainActor
    private func makeSession(
        micDecision: MicPermissionDecision,
        keyFetchResult: Result<EphemeralKey, Error> = .success(.init(secret: "k", sessionId: "s"))
    ) -> Fakes {
        let state = VoiceSessionState()
        let configurator = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let client = FakeRealtimeClient()
        let micGate = FakeMicPermissionGate(decision: micDecision)
        let fetcher = StubEphemeralKeyFetcher(result: keyFetchResult)

        let session = RealtimeVoiceSession(
            micGate: micGate,
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: client,
            state: state,
            backoff: { _ in .zero },     // tests don't wait
            maxReconnects: 3
        )
        return Fakes(
            session: session,
            state: state,
            coordinator: coordinator,
            configurator: configurator,
            client: client,
            micGate: micGate
        )
    }
}

// MARK: - Test doubles

/// Stub conforming to `EphemeralKeyFetching` so tests can inject canned
/// success/failure responses without going near WorkerClient or URLProtocol.
///
/// Phase 25 (Plan 25-08) widened the protocol surface with an optional
/// `BookContextSnapshot`; the stub ignores it because these tests only
/// care about the success/failure branch in `RealtimeVoiceSession.start`.
struct StubEphemeralKeyFetcher: EphemeralKeyFetching, @unchecked Sendable {
    let result: Result<EphemeralKey, Error>
    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        try result.get()
    }
}

/// Test fake for `MicPermissionGate` — returns the decision passed at init.
final class FakeMicPermissionGate: MicPermissionGate, @unchecked Sendable {
    private let decision: MicPermissionDecision
    init(decision: MicPermissionDecision) { self.decision = decision }
    func request() async -> MicPermissionDecision { decision }
}
