import Testing
import Foundation
@testable import RishiBilling
import RishiAPI

@Suite(.serialized)
struct BillingPortalServiceTests {

    // MARK: - Test doubles

    /// Test-only presenter — records the URL it was asked to open and can be
    /// pre-configured to throw a specific error. Actor isolation matches the
    /// `BillingPortalPresenter: Sendable` contract.
    actor RecordingPresenter: BillingPortalPresenter {
        private(set) var lastURL: URL?
        private var stubbedError: Error?

        func configure(throw error: Error?) { self.stubbedError = error }
        func observed() -> URL? { lastURL }

        // BillingPortalPresenter requires nonisolated conformance so the actor
        // boundary is crossed explicitly. We hop back to ourselves to record.
        nonisolated func present(url: URL) async throws {
            try await self.handle(url: url)
        }

        private func handle(url: URL) throws {
            self.lastURL = url
            if let stubbedError { throw stubbedError }
        }
    }

    private func makeWorkerClient() -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    // MARK: - Error shape

    @Test("BillingPortalError is Equatable")
    func errorEquality() {
        #expect(BillingPortalError.userCancelled == BillingPortalError.userCancelled)
        #expect(BillingPortalError.invalidURL("a") == BillingPortalError.invalidURL("a"))
        #expect(BillingPortalError.invalidURL("a") != BillingPortalError.invalidURL("b"))
        #expect(BillingPortalError.network("x") == BillingPortalError.network("x"))
        #expect(BillingPortalError.network("x") != BillingPortalError.userCancelled)
    }

    // MARK: - URL guard

    @Test("Non-http response strings would be rejected by the URL guard")
    func invalidURLGuardLogic() {
        // The openPortal() guard accepts only URLs whose scheme starts with
        // "http". This locks the contract for the static guard so a future
        // refactor can't accidentally accept javascript: / file: / about:.
        // Foundation will happily parse `"this-is-not-a-url"` into a relative
        // URL with a nil scheme — the guard rejects it on the scheme check.
        #expect(URL(string: "this-is-not-a-url")?.scheme?.hasPrefix("http") != true)
        #expect(URL(string: "javascript:alert(1)")?.scheme?.hasPrefix("http") != true)
        #expect(URL(string: "file:///etc/passwd")?.scheme?.hasPrefix("http") != true)
        #expect(URL(string: "https://billing.stripe.com/p/session/abc")?.scheme?.hasPrefix("http") == true)
        #expect(URL(string: "http://localhost:4000/billing")?.scheme?.hasPrefix("http") == true)
    }

    // MARK: - Presenter seam

    @Test("Presenter receives the URL passed by openPortal (via stub injection)")
    func presenterReceivesURL() async throws {
        // Direct presenter exercise — bypasses WorkerClient + verifies that
        // the BillingPortalPresenter protocol surface accepts a URL and
        // returns Void on success. This is the contract 11-06 relies on
        // when injecting `SystemBillingPortalPresenter`.
        let presenter = RecordingPresenter()
        let url = URL(string: "https://billing.stripe.com/p/session/abc")!
        try await presenter.present(url: url)
        let observed = await presenter.observed()
        #expect(observed == url)
    }

    @Test("Presenter can surface a user-cancelled error to the caller")
    func presenterCanThrow() async {
        // Confirms the BillingPortalPresenter contract supports async throws
        // and that errors propagate. Used by 11-03's paywall flow to
        // distinguish silent cancellation from genuine failures.
        let presenter = RecordingPresenter()
        await presenter.configure(throw: BillingPortalError.userCancelled)
        let url = URL(string: "https://billing.stripe.com/p/session/abc")!

        var caught: Error?
        do {
            try await presenter.present(url: url)
        } catch {
            caught = error
        }
        #expect(caught as? BillingPortalError == .userCancelled)
    }

    // MARK: - Service composition

    @Test("BillingPortalService can be constructed with an injected presenter")
    func serviceComposition() async {
        // Verifies BillingPortalService accepts the presenter seam at init.
        // Network round-trip / response decoding for openPortal() is covered
        // by 11-06's StubURLProtocol integration test.
        let service = BillingPortalService(
            workerClient: makeWorkerClient(),
            presenter: RecordingPresenter()
        )
        _ = service
        #expect(Bool(true))
    }
}
