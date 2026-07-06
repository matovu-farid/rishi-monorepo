import Testing
import Foundation
@testable import RishiBilling
import RishiCore

@Suite(.serialized)
struct EntitlementServiceTests {

    // MARK: - Helpers

    /// Build a fresh, isolated UserDefaults suite per test so tests can run in
    /// parallel without bleeding cache state into one another.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    /// Test-only WorkerClient pointing at an invalid host. Unit tests in this
    /// suite never actually exercise `refresh()` against the network — the
    /// integration coverage lives in 11-06 with StubURLProtocol.
    private func makeWorkerClient() -> WorkerClient {
        WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    // MARK: - EntitlementLevel model

    @Test("EntitlementLevel rawValues are stable")
    func entitlementLevelRawValuesStable() {
        #expect(EntitlementLevel.free.rawValue == "free")
        #expect(EntitlementLevel.pro.rawValue == "pro")
    }

    @Test("EntitlementLevel(hasPro:) maps booleans correctly")
    func entitlementLevelFromHasPro() {
        #expect(EntitlementLevel(hasPro: true) == .pro)
        #expect(EntitlementLevel(hasPro: false) == .free)
    }

    // MARK: - EntitlementService cache hydration

    @Test("Service hydrates from UserDefaults on init")
    func serviceHydratesFromDefaults() async {
        let defaults = makeDefaults()
        defaults.set("pro", forKey: "billing.entitlement.level")
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .pro)
    }

    @Test("Missing UserDefaults key defaults to .free")
    func missingCacheDefaultsToFree() async {
        let defaults = makeDefaults()
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .free)
    }

    @Test("Unknown rawValue in UserDefaults falls back to .free")
    func corruptCacheDefaultsToFree() async {
        let defaults = makeDefaults()
        defaults.set("enterprise-ultra", forKey: "billing.entitlement.level")
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .free)
    }

    // MARK: - setCached

    @Test("setCached updates snapshot and persists to UserDefaults")
    func setCachedPersists() async {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        await service.setCached(.pro)
        let snap = await service.snapshot()
        #expect(snap == .pro)

        // Re-open the same suite by name to read the persisted value from a
        // fresh, isolation-safe handle (Swift 6 strict concurrency dislikes
        // touching `defaults` after we sent it into the actor).
        let reader = UserDefaults(suiteName: suiteName)!
        #expect(reader.string(forKey: "billing.entitlement.level") == "pro")
    }

    // MARK: - clearCache

    @Test("clearCache resets snapshot to .free, persists .free, and emits .free")
    func clearCacheResetsToFree() async {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)

        var iter = service.currentLevel.makeAsyncIterator()
        // Drain the init yield (.free) before driving to .pro.
        _ = await iter.next()

        await service.setCached(.pro)
        #expect(await service.snapshot() == .pro)
        _ = await iter.next() // .pro emission

        await service.clearCache()
        #expect(await service.snapshot() == .free)

        let reader = UserDefaults(suiteName: suiteName)!
        #expect(reader.string(forKey: "billing.entitlement.level") == "free")

        let emitted = await iter.next()
        #expect(emitted == .free)
    }

    // MARK: - AsyncStream

    @Test("currentLevel stream yields cached value to first subscriber")
    func currentLevelYieldsCachedValue() async {
        let defaults = makeDefaults()
        defaults.set("pro", forKey: "billing.entitlement.level")
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)

        var iter = service.currentLevel.makeAsyncIterator()
        let first = await iter.next()
        #expect(first == .pro)
    }
}

// MARK: - Null session refresh (Phase 15 plan 05)
//
// Better Auth's `GET /api/auth/get-session` returns literal JSON `null` when
// the caller is unauthenticated. iOS must treat that as "no session, user is
// free-tier" rather than surfacing a decode error. The suite below scripts a
// URLProtocol to return a 200 with body "null" and asserts refresh succeeds
// with `.free` (not `.failure`).

/// Per-suite URLProtocol subclass so this suite's static handler does not race
/// with sibling suites in this test target.
final class NullSessionMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    static func reset() { handler = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let h = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, body) = h(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct EntitlementServiceNullSessionTests {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

    private func makeStubbedClient() -> WorkerClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NullSessionMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: session,
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    /// RED → GREEN driver for plan 15-05. Before the fix, the worker returns
    /// JSON `null`, `JSONDecoder` throws `valueNotFound`, and refresh()
    /// returns `.failure`. After the fix (Response = ProfileResponse?), the
    /// decoded value is `nil`, refresh yields `.free`, and the call succeeds.
    @Test("refresh on null session yields free level, not a failure")
    func refreshOnNullSessionYieldsFreeLevel() async {
        NullSessionMockURLProtocol.reset()
        NullSessionMockURLProtocol.handler = { _ in (200, Data("null".utf8)) }
        defer { NullSessionMockURLProtocol.reset() }

        let defaults = makeDefaults()
        let service = EntitlementService(workerClient: makeStubbedClient(), defaults: defaults)
        let result = await service.refresh()

        switch result {
        case .success(let level):
            #expect(level == .free)
        case .failure(let error):
            Issue.record("refresh should succeed with free level, got failure: \(error)")
        }
    }
}
