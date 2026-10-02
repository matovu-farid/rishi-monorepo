import Testing

@testable import rishi

@Suite("Shared reading reconnect decisions")
struct SharedReadingReconnectTests {
    @Test("connection errors refresh only the credential that expired")
    func classifiesCredentialRefreshes() {
        #expect(SharedReadingReconnectDecision.forError(.authRequired) == .refreshBearer)
        #expect(SharedReadingReconnectDecision.forError(.reconnectExpired) == .refreshAdmission)
    }

    @Test("terminal room errors stop reconnecting")
    func classifiesTerminalErrors() {
        #expect(SharedReadingReconnectDecision.forError(.sessionEnded) == .stop(.sessionEnded))
        #expect(SharedReadingReconnectDecision.forError(.removedFromSession) == .stop(.removedFromSession))
        #expect(SharedReadingReconnectDecision.forError(.accountDeleted) == .stop(.accountDeleted))
    }

    @Test("terminal signaling events await coordinator authority validation")
    func terminalRoomEventsDoNotTerminateImmediately() {
        let state = SharedReadingSessionStateEvent(sessionId: "stale", roomEpoch: 1, controllerGeneration: 1, connectionGeneration: 1, status: .ended, controllerUserId: "old")
        let ended = SharedReadingSessionEndedEvent(sessionId: "stale", roomEpoch: 1, controllerGeneration: 1, connectionGeneration: 1, reason: .controllerEnded)

        #expect(!SharedReadingSignalingClient.shouldTerminateImmediately(after: .sessionState(state)))
        #expect(!SharedReadingSignalingClient.shouldTerminateImmediately(after: .sessionEnded(ended)))
    }
}
