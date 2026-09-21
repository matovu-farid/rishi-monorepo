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
    }
}
