import Foundation
import Testing

@testable import rishi

@Suite("Rishi API environment")
struct RishiAPIEnvironmentTests {
    private let productionInfo: [String: Any] = [
        "RishiAPIBaseURL": "https://api.fidexa.org",
        "RishiSharingWebSocketURL": "wss://sharing.fidexa.org"
    ]

    private let e2eGates = [
        "RISHI_UITEST": "1",
        "RISHI_E2E_REAL_AUTH": "1"
    ]

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
            info: productionInfo,
            environment: [:]
        )

        #expect(environment?.mode == .production)
        #expect(environment?.httpBaseURL.absoluteString == "https://api.fidexa.org")
        #expect(environment?.sharingWebSocketURL.absoluteString == "wss://sharing.fidexa.org")
    }

    @Test("selects the exact E2E origins only for a gated Debug launch")
    func selectsGatedLiveE2EConfiguration() {
        let environment = RishiAPIEnvironment.load(
            info: productionInfo,
            environment: e2eGates.merging([
                "RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org",
                "RISHI_E2E_SHARING_WS_URL": "wss://sharing-e2e.fidexa.org"
            ]) { _, new in new }
        )

        #if DEBUG
        #expect(environment?.mode == .liveE2E)
        #expect(environment?.httpBaseURL.absoluteString == "https://api-e2e.fidexa.org")
        #expect(environment?.sharingWebSocketURL.absoluteString == "wss://sharing-e2e.fidexa.org")
        #else
        #expect(environment?.mode == .production)
        #expect(environment?.httpBaseURL.absoluteString == "https://api.fidexa.org")
        #expect(environment?.sharingWebSocketURL.absoluteString == "wss://sharing.fidexa.org")
        #endif
    }

    @Test("gated Debug launches fail closed for every non-allowlisted endpoint pair")
    func rejectsNonAllowlistedGatedEndpoints() {
        let invalidPairs: [(String?, String?)] = [
            (nil, "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", nil),
            ("not-a-url", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "not-a-url"),
            ("https://api.fidexa.org", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing.fidexa.org"),
            ("https://user:password@api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org/path", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org?query=1", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org#fragment", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org:443", "wss://sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org:443"),
            ("https://api-e2e.fidexa.org", "wss://user:password@sharing-e2e.fidexa.org"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org/path"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org?query=1"),
            ("https://api-e2e.fidexa.org", "wss://sharing-e2e.fidexa.org#fragment")
        ]

        for (http, webSocket) in invalidPairs {
            let environment = RishiAPIEnvironment.load(
                info: productionInfo,
                environment: e2eGates.merging([
                    "RISHI_E2E_API_BASE_URL": http ?? "",
                    "RISHI_E2E_SHARING_WS_URL": webSocket ?? ""
                ]) { _, new in new }
            )

            #if DEBUG
            #expect(environment == nil, "Rejected pair: \(String(describing: http)), \(String(describing: webSocket))")
            #else
            #expect(environment?.mode == .production)
            #expect(environment?.httpBaseURL.absoluteString == "https://api.fidexa.org")
            #expect(environment?.sharingWebSocketURL.absoluteString == "wss://sharing.fidexa.org")
            #endif
        }
    }

    @Test("non-gated launches preserve production and ignore E2E variables")
    func nonGatedLaunchPreservesProduction() {
        let environment = RishiAPIEnvironment.load(
            info: productionInfo,
            environment: [
                "RISHI_E2E_API_BASE_URL": "https://api-e2e.fidexa.org",
                "RISHI_E2E_SHARING_WS_URL": "wss://sharing-e2e.fidexa.org"
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
