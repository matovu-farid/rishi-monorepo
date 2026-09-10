import Foundation
import Testing

@testable import rishi

@Suite("Rishi API environment")
struct RishiAPIEnvironmentTests {
    @Test("accepts explicitly supplied endpoint values")
    func acceptsExplicitEndpoints() {
        let environment = RishiAPIEnvironment(
            mode: .production,
            httpBaseURL: URL(string: "https://api.fidexa.org")!,
            sharingWebSocketURL: URL(string: "wss://sharing.fidexa.org")!
        )

        #expect(environment?.mode == .production)
        #expect(environment?.httpBaseURL.absoluteString == "https://api.fidexa.org")
        #expect(environment?.sharingWebSocketURL.absoluteString == "wss://sharing.fidexa.org")
    }

    @Test("loads the compiled production configuration")
    func loadsCompiledProductionConfiguration() {
        let environment = RishiAPIEnvironment.load(
            info: [
                "RishiAPIBaseURL": "https://api.fidexa.org",
                "RishiSharingWebSocketURL": "wss://sharing.fidexa.org"
            ]
        )

        #expect(environment?.mode == .production)
        #expect(environment?.httpBaseURL.absoluteString == "https://api.fidexa.org")
        #expect(environment?.sharingWebSocketURL.absoluteString == "wss://sharing.fidexa.org")
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
            mode: .production,
            httpBaseURL: URL(string: "not-a-url")!,
            sharingWebSocketURL: URL(string: "wss://sharing.fidexa.org")!
        ) == nil)
        #expect(RishiAPIEnvironment(
            mode: .production,
            httpBaseURL: URL(string: "https://api.fidexa.org?production=true")!,
            sharingWebSocketURL: URL(string: "wss://sharing.fidexa.org")!
        ) == nil)
    }
}
