@testable import rishi
import Testing
import Foundation




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
        await fakes.session.start()
        #expect(fakes.state.status == .live)
        #expect(fakes.client.connectCalls == ["k"])
        #expect(fakes.client.micCaptureEnabledCalls == [true])
        #expect(fakes.fetcher.lastLanguage() == "en")
        #expect(await fakes.coordinator.currentMode == .voice)
    }

    @Test("Preflighted start skips duplicate microphone permission request and audio configuration")
    func preflightedStartSkipsDuplicateSetup() async throws {
        let fakes = makeSession(micDecision: .granted)

        // Model the presenter having already completed the permission + audio
        // session preflight before handing control to the lifecycle actor.
        await fakes.coordinator.requestActiveMode(.voice)
        let configureCallsAfterPreflight = fakes.configurator.configureCalls.count
        await fakes.session.start(preflighted: true)

        #expect(fakes.state.status == .live)
        #expect(fakes.micGate.requestCount == 0)
        #expect(fakes.configurator.configureCalls.count == configureCallsAfterPreflight)
        #expect(fakes.client.connectCalls == ["k"])
        _ = await fakes.session.end()
    }

    @Test("Explicit language is forwarded into the ephemeral-key fetch")
    func explicitLanguageIsForwarded() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "es")
        #expect(fakes.state.status == .live)
        #expect(fakes.fetcher.lastLanguage() == "es")
    }

    @Test("End: live → ending → ended releases audio mode + disconnects client")
    func endReleasesAudioMode() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        #expect(fakes.state.status == .live)
        let firstId = await fakes.session.end()
        #expect(firstId == nil) // legacy flow has no Rishi session id
        #expect(fakes.state.status == .ended)
        #expect(fakes.client.cancelCurrentResponseCalls == 1)
        #expect(fakes.client.disconnectCalls == 1)
        #expect(await fakes.coordinator.currentMode == .idle)
    }

    @Test("End re-entry is a no-op — second call does not disconnect again")
    func endReentryIsNoOp() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        _ = await fakes.session.end()
        #expect(fakes.client.disconnectCalls == 1)

        let secondId = await fakes.session.end()
        #expect(secondId == nil)
        #expect(fakes.client.disconnectCalls == 1)
        #expect(fakes.state.status == .ended)
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
        await fakes.session.start(language: "es")
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
        #expect(fakes.fetcher.lastLanguage() == "es")
        #expect(fakes.state.status == .live)
    }

    @Test("Reconnect: a single transient .disconnected sample does NOT reconnect")
    func transientBlipDoesNotReconnect() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        #expect(fakes.state.status == .live)

        // Model one momentary .disconnected status read followed by recovery —
        // exactly the kind of blip a healthy session can briefly report. The
        // observer must CONFIRM the drop is sustained before tearing the peer
        // down; a single sample must be ignored. Without confirmation this
        // reconnects (connectCalls == 2) and, in production, spawns a second
        // overlapping voice.
        fakes.client.scriptStatuses([.disconnected, .connected])

        // Give the observer several poll cycles to consume the blip + recover.
        try? await Task.sleep(for: .milliseconds(400))

        #expect(fakes.client.connectCalls.count == 1)  // no reconnect
        #expect(fakes.state.status == .live)
    }

    @Test("parkForBackground cancels reconnect observation and mutes transport")
    func parkCancelsReconnectObservationAndMutesTransport() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        await fakes.session.parkForBackground()
        fakes.client.setStatus(.disconnected)

        // The reconnect observer is cancelled while parked, so a sustained
        // disconnect must not create a new WebRTC connection.
        try? await Task.sleep(for: .milliseconds(1800))
        #expect(fakes.client.connectCalls.count == 1)
        #expect(fakes.state.status == .live)
        #expect(fakes.client.cancelCurrentResponseCalls == 1)
        #expect(fakes.client.micCaptureEnabledCalls == [false])
        #expect(fakes.client.assistantOutputEnabledCalls == [false])
    }

    @Test("resumeFromBackground restores live when transport is connected")
    func resumeFromBackgroundRestoresLive() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start()
        await fakes.session.parkForBackground()
        fakes.client.setStatus(.connected)
        await fakes.session.resumeFromBackground()
        #expect(fakes.state.status == .live)
        #expect(fakes.state.activityPhase == .listening)
        #expect(fakes.client.connectCalls.count == 1)
        #expect(fakes.client.micCaptureEnabledCalls == [false, true])
        #expect(fakes.client.assistantOutputEnabledCalls == [false, true])
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
        #expect(first?.mode == .videoChat)
        #expect(fakes.client.connectCalls == ["k"])
    }

    @Test("Trial startup exposes live transport before ledger registration completes")
    func trialStartupDoesNotBlockOnCallRegistration() async throws {
        let registrationGate = DelayedTrialRegistrationGate()
        let state = VoiceSessionState()
        let configurator = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let client = FakeRealtimeClient()
        client.setProviderCallId("call-1")
        let session = RealtimeVoiceSession(
            coordinator: coordinator,
            keyFetcher: StubEphemeralKeyFetcher(result: .success(.init(secret: "legacy", sessionId: "legacy"))),
            client: client,
            state: state,
            sessionCoordinator: DelayedTrialSessionCoordinator(gate: registrationGate),
            backoff: { _ in .zero },
            maxReconnects: 3
        )

        let startTask = Task { await session.start() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline,
              state.status != .registeringCall,
              state.status != .live {
            try? await Task.sleep(for: .milliseconds(5))
        }

        // The WebRTC transport is usable while the ledger's second HTTP call
        // is still pending. This is the perceived-startup latency boundary.
        #expect(state.status == .live)
        #expect(await registrationGate.didEnter)

        await registrationGate.release()
        await startTask.value
        #expect(state.status == .live)
        _ = await session.end()
    }

    // MARK: - Builders

    struct Fakes {
        let session: RealtimeVoiceSession
        let state: VoiceSessionState
        let coordinator: AudioSessionCoordinator
        let configurator: FakeAudioSessionConfigurator
        let client: FakeRealtimeClient
        let fetcher: CapturingEphemeralKeyFetcher
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
        let fetcher = CapturingEphemeralKeyFetcher(result: keyFetchResult)

        let session = RealtimeVoiceSession(
            coordinator: coordinator,
            keyFetcher: fetcher,
            client: client,
            state: state,
            backoff: { _ in .zero },     // tests don't wait
            maxReconnects: 3,
            confirmationInterval: .zero  // confirm drops without real delay
        )
        return Fakes(
            session: session,
            state: state,
            coordinator: coordinator,
            configurator: configurator,
            client: client,
            fetcher: fetcher,
            micGate: micGate
        )
    }
}

private actor DelayedTrialRegistrationGate {
    private(set) var didEnter = false
    private var isReleased = false

    func enter() {
        didEnter = true
    }

    func release() {
        isReleased = true
    }

    func waitForRelease() async {
        while !isReleased {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct DelayedTrialSessionCoordinator: VoiceSessionCoordinating {
    let gate: DelayedTrialRegistrationGate

    func startSession(
        language: String?,
        bookContext: BookContextSnapshot?
    ) async throws -> StartedVoiceSession {
        StartedVoiceSession(
            rishiSessionId: "rishi-session",
            nonce: "nonce",
            clientSecret: "trial-secret",
            capIntervals: 10,
            realtimeModel: "gpt-realtime-2.1-mini"
        )
    }

    func registerCall(rishiSessionId: String, callId: String, nonce: String) async throws {
        await gate.enter()
        await gate.waitForRelease()
    }
}

/// Test fake for `MicPermissionGate` — returns the decision passed at init.
final class FakeMicPermissionGate: MicPermissionGate, @unchecked Sendable {
    private let decision: MicPermissionDecision
    private(set) var requestCount = 0
    init(decision: MicPermissionDecision) { self.decision = decision }
    func request() async -> MicPermissionDecision {
        requestCount += 1
        return decision
    }
}
