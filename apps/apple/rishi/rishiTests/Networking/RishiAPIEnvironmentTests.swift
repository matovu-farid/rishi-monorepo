import Foundation
import Testing

@testable import rishi

@Suite("Rishi API environment")
struct RishiAPIEnvironmentTests {
    @Test("accepts local development HTTP and WebSocket endpoints")
    func acceptsDevelopmentEndpoints() {
        let environment = RishiAPIEnvironment(
            mode: .development,
            httpBaseURL: URL(string: "http://127.0.0.1:8787")!,
            sharingWebSocketURL: URL(string: "ws://127.0.0.1:8788")!
        )

        #expect(environment?.mode == .development)
        #expect(environment?.httpBaseURL.absoluteString == "http://127.0.0.1:8787")
        #expect(environment?.sharingWebSocketURL.absoluteString == "ws://127.0.0.1:8788")
    }

    @Test("accepts production endpoints")
    func acceptsProductionEndpoints() {
        let environment = RishiAPIEnvironment(
            mode: .production,
            httpBaseURL: URL(string: "https://api.fidexa.org")!,
            sharingWebSocketURL: URL(string: "wss://sharing.fidexa.org")!
        )

        #expect(environment?.mode == .production)
    }

    @Test("rejects malformed or query-bearing endpoints")
    func rejectsMalformedEndpoints() {
        #expect(RishiAPIEnvironment(
            mode: .development,
            httpBaseURL: URL(string: "not-a-url")!,
            sharingWebSocketURL: URL(string: "ws://127.0.0.1:8788")!
        ) == nil)
        #expect(RishiAPIEnvironment(
            mode: .development,
            httpBaseURL: URL(string: "http://127.0.0.1:8787?production=true")!,
            sharingWebSocketURL: URL(string: "ws://127.0.0.1:8788")!
        ) == nil)
    }
}
