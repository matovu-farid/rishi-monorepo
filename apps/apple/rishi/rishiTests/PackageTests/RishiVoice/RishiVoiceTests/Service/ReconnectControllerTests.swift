@testable import rishi
import Testing
import Foundation




/// Tests for `ReconnectController` — the reconnect engine extracted from
/// `RealtimeVoiceSession` (plan 34-13). Drives the controller directly with
/// `FakeRealtimeClient` + a stub key fetcher + recording callbacks, asserting
/// the backoff-ladder decisions in isolation:
///   - a sustained `.disconnected` drop runs the ladder and recovers (onReconnected),
///   - a single transient blip is debounced away (no reconnect),
///   - persistent connect failure exhausts the ladder (onExhausted),
///   - `isEnding` short-circuits before any reconnect work.
///
/// `.serialized` because the controller polls real (zeroed) timers and the
/// recorder is lock-guarded mutable state.
@Suite("ReconnectController backoff ladder", .serialized)
struct ReconnectControllerTests {

    /// Thread-safe recorder for the controller's callbacks.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _reconnecting: [Int] = []
        private var _reconnected: [Int] = []
        private var _exhausted = 0
        private var _isEnding = false

        var reconnecting: [Int] { lock.withLock { _reconnecting } }
        var reconnected: [Int] { lock.withLock { _reconnected } }
        var exhausted: Int { lock.withLock { _exhausted } }

        func setEnding(_ v: Bool) { lock.withLock { _isEnding = v } }
        func isEnding() -> Bool { lock.withLock { _isEnding } }
        func didReconnecting(_ a: Int) { lock.withLock { _reconnecting.append(a) } }
        func didReconnected(_ a: Int) { lock.withLock { _reconnected.append(a) } }
        func didExhausted() { lock.withLock { _exhausted += 1 } }
    }

    private func makeController(
        client: FakeRealtimeClient,
        recorder: Recorder,
        keyFetchResult: Result<EphemeralKey, Error> = .success(.init(secret: "k2", sessionId: "s2")),
        maxReconnects: Int = 3
    ) -> ReconnectController {
        let callbacks = ReconnectController.Callbacks(
            isEnding: { recorder.isEnding() },
            onReconnecting: { recorder.didReconnecting($0) },
            onReconnected: { recorder.didReconnected($0) },
            onExhausted: { recorder.didExhausted() }
        )
        return ReconnectController(
            client: client,
            keyFetcher: StubEphemeralKeyFetcher(result: keyFetchResult),
            backoff: { _ in .zero },
            maxReconnects: maxReconnects,
            disconnectConfirmations: 3,
            confirmationInterval: .zero,
            observationGracePeriod: .zero,
            callbacks: callbacks
        )
    }

    @Test("sustained disconnect → backoff ladder reconnects on attempt 1")
    func sustainedDisconnectReconnects() async throws {
        let client = FakeRealtimeClient()
        let recorder = Recorder()
        let controller = makeController(client: client, recorder: recorder)

        client.setStatus(.disconnected)   // sustained drop
        await controller.startStatusObservation()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if !recorder.reconnected.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.reconnecting == [1])
        #expect(recorder.reconnected == [1])
        #expect(recorder.exhausted == 0)
        #expect(client.connectCalls == ["k2"])  // one reconnect connect
    }

    @Test("single transient .disconnected blip is debounced → no reconnect")
    func transientBlipDebounced() async throws {
        let client = FakeRealtimeClient()
        let recorder = Recorder()
        let controller = makeController(client: client, recorder: recorder)

        // First poll reads .disconnected, confirm re-poll reads .connected →
        // confirmDisconnect aborts, no reconnect.
        client.scriptStatuses([.disconnected, .connected, .connected, .connected])
        await controller.startStatusObservation()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.reconnecting.isEmpty)
        #expect(recorder.reconnected.isEmpty)
        #expect(client.connectCalls.isEmpty)
        await controller.cancel()
    }

    @Test("persistent connect failure exhausts the ladder → onExhausted")
    func exhaustsAfterMaxReconnects() async throws {
        struct StubFail: Error {}
        let client = FakeRealtimeClient()
        let recorder = Recorder()
        let controller = makeController(client: client, recorder: recorder, maxReconnects: 3)

        client.failAllConnects(with: StubFail())
        client.setStatus(.disconnected)
        await controller.startStatusObservation()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if recorder.exhausted > 0 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(recorder.reconnecting == [1, 2, 3])
        #expect(recorder.reconnected.isEmpty)
        #expect(recorder.exhausted == 1)
        #expect(client.connectCalls.count == 3)  // 3 failed reconnect attempts
    }

    @Test("isEnding short-circuits confirmDisconnect → no reconnect")
    func isEndingShortCircuits() async throws {
        let client = FakeRealtimeClient()
        let recorder = Recorder()
        let controller = makeController(client: client, recorder: recorder)

        recorder.setEnding(true)          // session already tearing down
        client.setStatus(.disconnected)
        await controller.startStatusObservation()

        try? await Task.sleep(for: .milliseconds(200))
        #expect(recorder.reconnecting.isEmpty)
        #expect(recorder.exhausted == 0)
        #expect(client.connectCalls.isEmpty)
        await controller.cancel()
    }
}
