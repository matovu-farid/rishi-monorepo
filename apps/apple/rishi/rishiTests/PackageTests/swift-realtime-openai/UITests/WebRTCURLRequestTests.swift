@testable import rishi
import Foundation
import Testing



@Suite("WebRTC connection URL")
struct WebRTCURLRequestTests {
    @Test("omits model query when no model is supplied")
    func omitsModelQueryByDefault() {
        let request = URLRequest.webRTCConnectionRequest(ephemeralKey: "ephemeral")

        #expect(request.url?.absoluteString == "https://api.openai.com/v1/realtime/calls")
    }

    @Test("preserves explicit model query for compatibility")
    func includesExplicitModelQuery() {
        let request = URLRequest.webRTCConnectionRequest(
            ephemeralKey: "ephemeral",
            model: .gptRealtimeMini
        )

        #expect(request.url?.query == "model=gpt-realtime-2.1-mini")
    }
}
