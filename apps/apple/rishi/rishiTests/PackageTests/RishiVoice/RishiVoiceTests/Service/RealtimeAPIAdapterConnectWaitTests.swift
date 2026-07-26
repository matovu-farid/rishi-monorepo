@testable import rishi
import Testing
import Foundation




/// Regression: the OpenAI Realtime SDK's `Conversation.connect()` returns after
/// the SDP exchange but BEFORE the WebRTC data channel opens. During that window
/// `status` reports `.disconnected` — its initial value. The SDK's
/// `WebRTCConnector` only flips status to `.connected` on
/// `dataChannelDidChangeState(.open)`; raw ICE-state changes never touch status.
///
/// If the adapter returned from `connect()` during that window, the session's
/// 10Hz status observer would read `.disconnected`, treat it as a lost
/// connection, and reconnect — spawning a SECOND peer whose audio overlaps the
/// first ("two voices"/echo) and an endless connect->reconnect loop (each fresh
/// peer is also momentarily `.disconnected`, re-triggering the observer).
///
/// `connect()` therefore MUST wait until the data channel actually opens before
/// reporting connected. `waitUntilConnected` is the testable core of that wait.
@Suite("RealtimeAPIAdapter connect-wait")
struct RealtimeAPIAdapterConnectWaitTests {

    /// Lock-guarded poll probe that reports "connected" only after `flipAt`
    /// polls — models the SDK's data-channel-open delay deterministically.
    final class FlipAfter: @unchecked Sendable {
        private let lock = NSLock()
        private var polls = 0
        private let flipAt: Int
        init(flipAt: Int) { self.flipAt = flipAt }
        var pollCount: Int { lock.withLock { polls } }
        func isConnected() -> Bool {
            lock.withLock {
                polls += 1
                return polls >= flipAt
            }
        }
    }

    @Test("returns only once the connection reports connected")
    func returnsWhenConnected() async throws {
        let probe = FlipAfter(flipAt: 3)
        try await RealtimeAPIAdapter.waitUntilConnected(
            timeout: .seconds(2),
            pollInterval: .milliseconds(5)
        ) { probe.isConnected() }
        #expect(probe.pollCount >= 3)
    }

    @Test("throws connect_timeout when the data channel never opens")
    func throwsOnTimeout() async {
        await #expect(throws: RealtimeClientError.self) {
            try await RealtimeAPIAdapter.waitUntilConnected(
                timeout: .milliseconds(40),
                pollInterval: .milliseconds(10)
            ) { false }
        }
    }

    @Test("event-driven wait returns on the data-channel status event")
    func returnsOnStatusEvent() async throws {
        let (updates, continuation) = AsyncStream.makeStream(of: RealtimeAPI.Status.self)
        let producer = Task {
            try? await Task.sleep(for: .milliseconds(5))
            continuation.yield(.connected)
            continuation.finish()
        }
        defer { producer.cancel(); continuation.finish() }

        try await RealtimeAPIAdapter.waitUntilConnected(
            timeout: .seconds(1),
            statusUpdates: updates
        )
    }
}
