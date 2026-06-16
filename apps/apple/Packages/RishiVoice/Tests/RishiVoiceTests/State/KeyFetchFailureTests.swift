import Testing
import Foundation
@testable import RishiVoice
import RishiCore

/// Unit tests for the pure `KeyFetchFailure.classify` mapper. Each row feeds
/// a `RishiError` (the type the network layer throws) and asserts the
/// classified `KeyFetchFailure`. This is the contract the UI relies on to
/// tell a missing-route 404 apart from "signed out" or "not subscribed".
@Suite("KeyFetchFailure.classify")
struct KeyFetchFailureTests {

    @Test("401 unauthenticated maps to .unauthorized")
    func unauthenticatedMapsToUnauthorized() {
        #expect(KeyFetchFailure.classify(RishiError.unauthenticated) == .unauthorized)
    }

    @Test("402 BILLING_INACTIVE maps to .subscriptionRequired")
    func billingInactiveMapsToSubscriptionRequired() {
        let error = RishiError.network(code: "BILLING_INACTIVE", message: "Pro required")
        #expect(KeyFetchFailure.classify(error) == .subscriptionRequired)
    }

    @Test("404 http_4xx maps to .serviceUnavailable")
    func http4xxMapsToServiceUnavailable() {
        let error = RishiError.network(code: "http_4xx", message: "HTTP 404")
        #expect(KeyFetchFailure.classify(error) == .serviceUnavailable)
    }

    @Test("5xx http_5xx maps to .serviceUnavailable")
    func http5xxMapsToServiceUnavailable() {
        let error = RishiError.network(code: "http_5xx", message: "HTTP 5xx")
        #expect(KeyFetchFailure.classify(error) == .serviceUnavailable)
    }

    @Test("Any other network code maps to .serviceUnavailable")
    func otherNetworkCodeMapsToServiceUnavailable() {
        let error = RishiError.network(code: "SOMETHING_ELSE", message: "boom")
        #expect(KeyFetchFailure.classify(error) == .serviceUnavailable)
    }

    @Test("Transport failure maps to .network")
    func networkFailureMapsToNetwork() {
        let error = RishiError.networkFailure(URLError(.notConnectedToInternet))
        #expect(KeyFetchFailure.classify(error) == .network)
    }

    @Test("Non-RishiError maps to .unknown carrying a description")
    func nonRishiErrorMapsToUnknown() {
        struct Other: Error {}
        let result = KeyFetchFailure.classify(Other())
        if case .unknown(let detail) = result {
            #expect(!detail.isEmpty)
        } else {
            Issue.record("Expected .unknown, got \(result)")
        }
    }

    @Test("Unmapped RishiError case maps to .unknown")
    func unmappedRishiErrorMapsToUnknown() {
        let result = KeyFetchFailure.classify(RishiError.notFound)
        if case .unknown = result {
            // ok
        } else {
            Issue.record("Expected .unknown, got \(result)")
        }
    }
}
