@testable import rishi
import Testing
import Foundation



@Suite(.serialized)
struct EntitlementServiceTests {

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }

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
        #expect(EntitlementLevel.unsubscribed.rawValue == "unsubscribed")
        #expect(EntitlementLevel.subscribed.rawValue == "subscribed")
    }

    @Test("EntitlementLevel(hasPro:) maps booleans correctly")
    func entitlementLevelFromHasPro() {
        #expect(EntitlementLevel(hasPro: true) == .subscribed)
        #expect(EntitlementLevel(hasPro: false) == .unsubscribed)
    }

    // MARK: - EntitlementService cache hydration

    @Test("Service hydrates from UserDefaults on init")
    func serviceHydratesFromDefaults() async {
        let defaults = makeDefaults()
        defaults.set("subscribed", forKey: EntitlementService.defaultsKey)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .subscribed)
    }

    @Test("Missing UserDefaults key defaults to .unsubscribed")
    func missingCacheDefaultsToFree() async {
        let defaults = makeDefaults()
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .unsubscribed)
    }

    @Test("Unknown rawValue in UserDefaults falls back to .unsubscribed")
    func corruptCacheDefaultsToFree() async {
        let defaults = makeDefaults()
        defaults.set("enterprise-ultra", forKey: EntitlementService.defaultsKey)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        let snap = await service.snapshot()
        #expect(snap == .unsubscribed)
    }

    // MARK: - setCached

    @Test("setCached updates snapshot and persists to UserDefaults")
    func setCachedPersists() async {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        await service.setCached(.subscribed)
        let snap = await service.snapshot()
        #expect(snap == .subscribed)

        let reader = UserDefaults(suiteName: suiteName)!
        #expect(reader.string(forKey: EntitlementService.defaultsKey) == "subscribed")
    }

    // MARK: - clearCache

    @Test("clearCache resets snapshot to .unsubscribed, persists, and emits")
    func clearCacheResetsToFree() async {
        let suiteName = "test.billing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)

        var iter = service.currentLevel.makeAsyncIterator()
        _ = await iter.next()

        await service.setCached(.subscribed)
        #expect(await service.snapshot() == .subscribed)
        _ = await iter.next()

        await service.clearCache()
        #expect(await service.snapshot() == .unsubscribed)

        let reader = UserDefaults(suiteName: suiteName)!
        #expect(reader.string(forKey: EntitlementService.defaultsKey) == "unsubscribed")

        let emitted = await iter.next()
        #expect(emitted == .unsubscribed)
    }

    // MARK: - AsyncStream

    @Test("currentLevel stream yields cached value to first subscriber")
    func currentLevelYieldsCachedValue() async {
        let defaults = makeDefaults()
        defaults.set("subscribed", forKey: EntitlementService.defaultsKey)
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)

        var iter = service.currentLevel.makeAsyncIterator()
        let first = await iter.next()
        #expect(first == .subscribed)
    }

    // MARK: - Resolution stream

    @Test("resolution starts unresolved")
    func resolutionStartsUnresolved() async {
        let service = EntitlementService(
            workerClient: makeWorkerClient(),
            defaults: makeDefaults()
        )
        #expect(await service.resolutionNow() == .unresolved)
    }

    @Test("bindToUser hydrates persisted snapshot resolution")
    func bindToUserHydratesCache() async {
        let defaults = makeDefaults()
        let userId = "user-123"
        let snapshot = EntitlementSnapshot.trialActive(remainingCredits: 42)
        let payload = CachedEntitlementSnapshotPayloadForTests(
            cachedAt: Date(timeIntervalSince1970: 1_700_000_000),
            snapshot: snapshot
        )
        let data = try! JSONEncoder().encode(payload)
        defaults.set(data, forKey: "billing.entitlement.snapshot.v1.\(userId)")

        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        await service.bindToUser(userId: userId)

        let resolution = await service.resolutionNow()
        guard case .resolved(let cached, let fetchedAt) = resolution else {
            Issue.record("Expected resolved snapshot after bindToUser")
            return
        }
        #expect(cached == snapshot)
        #expect(fetchedAt == payload.cachedAt)
    }

    @Test("clearSnapshotCache resets to unresolved and deletes persisted key")
    func clearSnapshotCacheResets() async {
        let defaults = makeDefaults()
        let userId = "user-456"
        let service = EntitlementService(workerClient: makeWorkerClient(), defaults: defaults)
        await service.bindToUser(userId: userId)
        _ = await service.refreshSnapshot(
            expectedUserId: userId,
            isCurrentUser: { true }
        ) // will fail network — stay unresolved

        // Manually seed resolved state through bind with fake cache
        let snapshot = EntitlementSnapshot.trialActive(remainingCredits: 10)
        let payload = CachedEntitlementSnapshotPayloadForTests(
            cachedAt: Date(),
            snapshot: snapshot
        )
        defaults.set(try! JSONEncoder().encode(payload), forKey: "billing.entitlement.snapshot.v1.\(userId)")
        await service.bindToUser(userId: userId)

        await service.clearSnapshotCache(for: userId)
        #expect(await service.resolutionNow() == .unresolved)
        #expect(defaults.data(forKey: "billing.entitlement.snapshot.v1.\(userId)") == nil)
    }

    @Test("refreshSnapshot account switch preserves hydrated B and both disk payloads")
    func refreshSnapshotAccountSwitchPreservesHydratedB() async {
        let serverSnapshot = EntitlementSnapshot.readerActive(
            EntitlementSnapshot.PaidPeriod(
                periodEndMs: 1_900_000_000_000,
                remainingNarrationSeconds: 1_200,
                remainingVoiceChatSeconds: 800
            )
        )
        let harness = EntitlementServiceSnapshotURLProtocolHarness(
            snapshot: serverSnapshot
        )
        defer { harness.reset() }

        let defaults = makeDefaults()
        let snapshotA = EntitlementSnapshot.trialActive(remainingCredits: 11)
        let snapshotB = EntitlementSnapshot.trialActive(remainingCredits: 22)
        let dataA = try! JSONEncoder().encode(
            CachedEntitlementSnapshotPayloadForTests(
                cachedAt: Date(timeIntervalSince1970: 1_700_000_000),
                snapshot: snapshotA
            )
        )
        let dataB = try! JSONEncoder().encode(
            CachedEntitlementSnapshotPayloadForTests(
                cachedAt: Date(timeIntervalSince1970: 1_700_000_100),
                snapshot: snapshotB
            )
        )
        defaults.set(dataA, forKey: cacheKey(for: "user-a"))
        defaults.set(dataB, forKey: cacheKey(for: "user-b"))

        let currentUser = LockedServiceUser("user-a")
        let service = EntitlementService(
            workerClient: makeWorkerClient(harness: harness),
            defaults: defaults
        )
        await service.bindToUser(userId: "user-a")

        let refresh = Task {
            await service.refreshSnapshot(
                expectedUserId: "user-a",
                isCurrentUser: { currentUser.current == "user-a" }
            )
        }
        defer {
            refresh.cancel()
            harness.releaseResponse()
        }

        guard harness.waitForRequest() else {
            Issue.record("Account A request did not start within 5 seconds")
            return
        }
        currentUser.set("user-b")
        await service.bindToUser(userId: "user-b")
        harness.releaseResponse()

        let result = await refresh.value
        guard case .failure(let error) = result else {
            Issue.record("Expected accountChanged failure for stale account A response")
            return
        }
        guard case EntitlementRefreshError.accountChanged = error else {
            Issue.record("Expected accountChanged, got \(error)")
            return
        }

        guard case .resolved(let hydratedB, _) = await service.resolutionNow() else {
            Issue.record("Expected user B to remain hydrated in memory")
            return
        }
        #expect(hydratedB == snapshotB)
        #expect(defaults.data(forKey: cacheKey(for: "user-a")) == dataA)
        #expect(defaults.data(forKey: cacheKey(for: "user-b")) == dataB)
    }

    private func makeWorkerClient(
        harness: EntitlementServiceSnapshotURLProtocolHarness
    ) -> WorkerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [harness.protocolClass]
        return WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            session: URLSession(configuration: configuration),
            tokenProvider: StaticTokenProvider(nil),
            devBypassEnabled: false
        )
    }

    private func cacheKey(for userId: String) -> String {
        "billing.entitlement.snapshot.v1.\(userId)"
    }
}

private struct CachedEntitlementSnapshotPayloadForTests: Codable {
    let cachedAt: Date
    let snapshot: EntitlementSnapshot
}

private final class LockedServiceUser: @unchecked Sendable {
    private let lock = NSLock()
    private var userId: String?

    init(_ userId: String?) {
        self.userId = userId
    }

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return userId
    }

    func set(_ userId: String?) {
        lock.lock()
        self.userId = userId
        lock.unlock()
    }
}

private final class EntitlementServiceSnapshotURLProtocolHarness: @unchecked Sendable {
    private let lock = NSLock()
    private let requestStarted = DispatchSemaphore(value: 0)
    private let responseGate = DispatchSemaphore(value: 0)
    private let response: Data
    private var requestCount = 0

    var protocolClass: URLProtocol.Type {
        EntitlementServiceSnapshotURLProtocol.self
    }

    init(snapshot: EntitlementSnapshot) {
        response = try! JSONEncoder().encode(snapshot)
        EntitlementServiceSnapshotURLProtocol.activate(self)
    }

    var requests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    func waitForRequest(timeout: TimeInterval = 5) -> Bool {
        requestStarted.wait(timeout: .now() + timeout) == .success
    }

    func releaseResponse() {
        responseGate.signal()
    }

    func reset() {
        EntitlementServiceSnapshotURLProtocol.deactivate(self)
    }

    fileprivate func handle(_ protocolObject: URLProtocol) {
        lock.lock()
        requestCount += 1
        lock.unlock()
        requestStarted.signal()

        guard responseGate.wait(timeout: .now() + 5) == .success else {
            protocolObject.client?.urlProtocol(
                protocolObject,
                didFailWithError: URLError(.timedOut)
            )
            return
        }

        let httpResponse = HTTPURLResponse(
            url: protocolObject.request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        protocolObject.client?.urlProtocol(
            protocolObject,
            didReceive: httpResponse,
            cacheStoragePolicy: .notAllowed
        )
        protocolObject.client?.urlProtocol(protocolObject, didLoad: response)
        protocolObject.client?.urlProtocolDidFinishLoading(protocolObject)
    }
}

private final class EntitlementServiceSnapshotURLProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated(unsafe) static var activeHarness:
        EntitlementServiceSnapshotURLProtocolHarness?

    fileprivate static func activate(
        _ harness: EntitlementServiceSnapshotURLProtocolHarness
    ) {
        activeHarness = harness
    }

    fileprivate static func deactivate(
        _ harness: EntitlementServiceSnapshotURLProtocolHarness
    ) {
        if activeHarness === harness {
            activeHarness = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let harness = Self.activeHarness else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        harness.handle(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite
struct EntitlementSnapshotStoreTests {

    @Test("blockReason is nil while unresolved")
    func blockReasonNilWhenUnresolved() async {
        let service = EntitlementService(
            workerClient: WorkerClient(
                baseURL: URL(string: "https://example.invalid")!,
                tokenProvider: StaticTokenProvider(nil),
                devBypassEnabled: false
            )
        )
        let store = EntitlementSnapshotStore(service: service)
        #expect(store.blockReason(for: .narration) == nil)
        #expect(store.blockReason(for: .voiceChat) == nil)
        #expect(store.isLoading)
    }
}

// MARK: - Null session refresh (Phase 15 plan 05)

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

    @Test("refresh on null session yields unsubscribed level, not a failure")
    func refreshOnNullSessionYieldsFreeLevel() async {
        NullSessionMockURLProtocol.reset()
        NullSessionMockURLProtocol.handler = { _ in (200, Data("null".utf8)) }
        defer { NullSessionMockURLProtocol.reset() }

        let defaults = makeDefaults()
        let service = EntitlementService(workerClient: makeStubbedClient(), defaults: defaults)
        let result = await service.refresh()

        switch result {
        case .success(let level):
            #expect(level == .unsubscribed)
        case .failure(let error):
            Issue.record("refresh should succeed with unsubscribed level, got failure: \(error)")
        }
    }
}
