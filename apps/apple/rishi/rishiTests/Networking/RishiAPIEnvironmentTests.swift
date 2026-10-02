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

    #if DEBUG
    @Test("selects exact live E2E endpoints only with both Debug gates")
    func selectsLiveE2EEndpointsWhenFullyGated() {
        let environment = RishiAPIEnvironment.load(
            info: productionInfo,
            environment: liveE2EEnvironment
        )

        #expect(environment?.mode == .liveE2E)
        #expect(environment?.httpBaseURL.absoluteString == "https://api-e2e.fidexa.org")
        #expect(environment?.sharingWebSocketURL.absoluteString == "wss://sharing-e2e.fidexa.org")
    }

    @Test("fails closed for invalid live E2E endpoints once gated")
    func failsClosedForInvalidGatedLiveE2EEndpoints() {
        let invalidValues: [(String, String)] = [
            ("", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", ""),
            ("not-a-url", "wss://sharing-e2e.fidexa.org"),
            ("https://api.fidexa.org", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing.fidexa.org"),
            ("https://api.fidexa.org", "wss://sharing.fidexa.org"),
            ("https://user:password@api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://user:password@sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org/path", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org/path"),
            ("https://api-e2e.fidexa.org?query=1", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org?query=1"),
            ("https://api-e2e.fidexa.org#fragment", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org#fragment"),
            ("https://api-e2e.fidexa.org:443", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org:443")
        ]

        for (httpBaseURL, sharingWebSocketURL) in invalidValues {
            var environment = liveE2EEnvironment
            environment["RISHI_E2E_API_BASE_URL"] = httpBaseURL
            environment["RISHI_E2E_SHARING_WS_URL"] = sharingWebSocketURL

            #expect(
                RishiAPIEnvironment.load(info: productionInfo, environment: environment) == nil,
                "Expected gated values to fail closed: \(httpBaseURL), \(sharingWebSocketURL)"
            )
        }
    }

    @Test("ignores E2E values when either Debug gate is absent")
    func ignoresE2EValuesWhenNotFullyGated() {
        for missingGate in ["RISHI_UITEST", "RISHI_E2E_REAL_AUTH"] {
            var environment = liveE2EEnvironment
            environment[missingGate] = "0"

            let loaded = RishiAPIEnvironment.load(info: productionInfo, environment: environment)

            #expect(loaded?.mode == .production)
            #expect(loaded?.httpBaseURL.absoluteString == "https://api.fidexa.org")
            #expect(loaded?.sharingWebSocketURL.absoluteString == "wss://sharing.fidexa.org")
        }
    }

    @Test("ignores E2E values when the Debug gates are missing")
    func ignoresE2EValuesWhenGatesAreMissing() {
        let loaded = RishiAPIEnvironment.load(
            info: productionInfo,
            environment: [
                "RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org",
                "RISHI_E2E_SHARING_WS_URL": "wss://sharing-e2e.fidexa.org"
            ]
        )

        #expect(loaded?.mode == .production)
        #expect(loaded?.httpBaseURL.absoluteString == "https://api.fidexa.org")
        #expect(loaded?.sharingWebSocketURL.absoluteString == "wss://sharing.fidexa.org")
    }
    #endif

    private var productionInfo: [String: Any] {
        [
            "RishiAPIBaseURL": "https://api.fidexa.org",
            "RishiSharingWebSocketURL": "wss://sharing.fidexa.org"
        ]
    }

    private var liveE2EEnvironment: [String: String] {
        [
            "RISHI_UITEST": "1",
            "RISHI_E2E_REAL_AUTH": "1",
            "RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org",
            "RISHI_E2E_SHARING_WS_URL": "wss://sharing-e2e.fidexa.org"
        ]
    }
}
