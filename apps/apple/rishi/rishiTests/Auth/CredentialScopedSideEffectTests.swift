import Foundation
import Synchronization
import Testing
@testable import rishi

@MainActor
@Suite("Credential scoped side effects — isolated stores and transport", .serialized, .timeLimit(.minutes(1)))
struct CredentialScopedSideEffectTests {
    private func client(_ authority: SessionCredentialAuthority) -> (WorkerClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialSideEffectURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        return (WorkerClient(baseURL: URL(string: "https://credential-effects.example.invalid")!, session: session,
            credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
            admitCredentialRejection: { _, _ in .stale }), session)
    }

    @Test("real UserDefaults and memory onboarding reject stale writes and accept the current lease")
    func onboardingActualAdmission() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let name = "CredentialScopedSideEffectTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let stores: [any CredentialOnboardingState] = [UserDefaultsOnboardingState(defaults: defaults), InMemoryOnboardingState()]
        let b = try installStagingCredentials("B", authority: authority)
        for store in stores {
            #expect(!(await store.setHasCompletedOnboarding(true, lease: a.lease, authority: authority)))
            #expect(!(await store.hasCompletedOnboarding()))
            #expect(await store.setHasCompletedOnboarding(true, lease: b.lease, authority: authority))
            #expect(await store.hasCompletedOnboarding())
            #expect(!(await store.setHasCompletedOnboarding(false, lease: a.lease, authority: authority)))
            #expect(await store.hasCompletedOnboarding())
        }
        let newer = try installStagingCredentials("B", authority: authority)
        for store in stores {
            #expect(!(await store.setHasCompletedOnboarding(false, lease: b.lease, authority: authority)))
            #expect(await store.hasCompletedOnboarding())
            #expect(await store.setHasCompletedOnboarding(false, lease: newer.lease, authority: authority))
            #expect(!(await store.hasCompletedOnboarding()))
        }
    }

    @Test("APNs deduplication retains the full credential lease, including account and raw-ID reuse")
    func registrarLeaseDedupe() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        CredentialSideEffectURLProtocol.setHandler { _ in }
        let (worker, session) = client(authority)
        defer { session.invalidateAndCancel(); CredentialSideEffectURLProtocol.reset() }
        let registrar = APNsDeviceRegistrar(workerClient: worker, credentialAuthority: authority)
        let token = Data([0x12, 0xab])
        try await registrar.register(token: token, platform: "ios", appVersion: "fixture", credentialContext: .normal(a.lease))
        try await registrar.register(token: token, platform: "ios", appVersion: "fixture", credentialContext: .normal(a.lease))
        #expect(CredentialSideEffectURLProtocol.requests.count == 1)
        let b = try installStagingCredentials("B", authority: authority)
        try await registrar.register(token: token, platform: "ios", appVersion: "fixture", credentialContext: .normal(b.lease))
        let sameRawB = try installStagingCredentials("B", authority: authority)
        try await registrar.register(token: token, platform: "ios", appVersion: "fixture", credentialContext: .normal(sameRawB.lease))
        #expect(CredentialSideEffectURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
            == ["Bearer fixture-A", "Bearer fixture-B", "Bearer fixture-B"])
        #expect(CredentialSideEffectURLProtocol.requests.allSatisfy { $0.url?.path == "/api/devices/register" && $0.httpMethod == "POST" })
        do { try await registrar.register(token: token, platform: "ios", appVersion: "fixture"); Issue.record("Unscoped mutation accepted") }
        catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        #expect(CredentialSideEffectURLProtocol.requests.count == 3)
    }

    @Test("mismatched registrar and Worker authorities fail before transport")
    func mismatchedAuthorityBeforeTransport() async throws {
        let storage = CredentialStagingMemoryPersistence()
        let seed = SessionCredentialAuthority(persistence: storage)
        _ = try installStagingCredentials("A", authority: seed)
        // Reload the same record into two competing owners so their full leases
        // are equal. Authority object identity must reject before transport.
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try authority.snapshot()
        let other = SessionCredentialAuthority(persistence: storage)
        let otherSnapshot = try other.snapshot()
        #expect(otherSnapshot.lease == a.lease)
        let (worker, session) = client(other)
        defer { session.invalidateAndCancel(); CredentialSideEffectURLProtocol.reset() }
        CredentialSideEffectURLProtocol.setHandler { _ in Issue.record("Mismatched authority reached transport") }
        let registrar = APNsDeviceRegistrar(workerClient: worker, credentialAuthority: authority)
        do {
            try await registrar.register(token: Data([1]), platform: "ios", appVersion: "fixture", credentialContext: .normal(a.lease))
            Issue.record("Mismatched authority accepted")
        } catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        #expect(CredentialSideEffectURLProtocol.requests.isEmpty)
    }

    @Test("late A registration cannot cache success or clear B's pending device token")
    func pendingTokenAfterAccountChange() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        CredentialSideEffectURLProtocol.setHandler { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-A" { await gate.suspend() }
        }
        let (worker, session) = client(authority)
        defer { session.invalidateAndCancel(); CredentialSideEffectURLProtocol.reset(); Task { await gate.resume() } }
        let registrar = APNsDeviceRegistrar(workerClient: worker, credentialAuthority: authority)
        let box = UserIdBox()
        let deps = AppDependencies(credentialAuthority: authority, userIdBox: box,
            accountGeneration: 17, persistAccountGeneration: { _ in }, credentialCleanup: { _ in })
        let background = BackgroundSyncLifecycle(dependencies: deps, userIdBox: box, credentialRegistrar: registrar)
        let token = Data([0xa1])
        await background.registerDeviceToken(token, platform: "ios", appVersion: "fixture")
        box.value = DerivedUserID.from("A")
        let attempt = Task { try await background.retryPendingDeviceTokenIfAvailable(
            platform: "ios", appVersion: "fixture", credentialContext: .normal(a.lease)) }
        defer { attempt.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        let b = try installStagingCredentials("B", authority: authority)
        box.value = DerivedUserID.from("B")
        await gate.resume()
        do { try await attempt.value; Issue.record("Late A success accepted") }
        catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        try await background.retryPendingDeviceTokenIfAvailable(platform: "ios", appVersion: "fixture", credentialContext: .normal(b.lease))
        #expect(CredentialSideEffectURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
            == ["Bearer fixture-A", "Bearer fixture-B"])
        // Successful B clears pending under B's actual mutation admission.
        try await background.retryPendingDeviceTokenIfAvailable(platform: "ios", appVersion: "fixture", credentialContext: .normal(b.lease))
        #expect(CredentialSideEffectURLProtocol.requests.count == 2)
    }

    @Test("registration only clears the captured pending token, preserving a later token for the same lease")
    func pendingTokenReplacement() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let first = Mutex(true)
        CredentialSideEffectURLProtocol.setHandler { _ in
            let pause = first.withLock { value in let captured = value; value = false; return captured }
            if pause { await gate.suspend() }
        }
        let (worker, session) = client(authority)
        defer { session.invalidateAndCancel(); CredentialSideEffectURLProtocol.reset(); Task { await gate.resume() } }
        let registrar = APNsDeviceRegistrar(workerClient: worker, credentialAuthority: authority)
        let box = UserIdBox()
        let deps = AppDependencies(credentialAuthority: authority, userIdBox: box,
            accountGeneration: 17, persistAccountGeneration: { _ in }, credentialCleanup: { _ in })
        let background = BackgroundSyncLifecycle(dependencies: deps, userIdBox: box, credentialRegistrar: registrar)
        await background.registerDeviceToken(Data([0x11]), platform: "ios", appVersion: "fixture")
        box.value = DerivedUserID.from("A")
        let attempt = Task { try await background.retryPendingDeviceTokenIfAvailable(
            platform: "ios", appVersion: "fixture", credentialContext: .normal(a.lease)) }
        defer { attempt.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        // Simulate a new APNs callback while no identity is exposed; this uses
        // the existing public pending-token capture, without any debug getter.
        box.value = nil
        await background.registerDeviceToken(Data([0x22]), platform: "ios", appVersion: "fixture")
        box.value = DerivedUserID.from("A")
        await gate.resume(); try await attempt.value
        try await background.retryPendingDeviceTokenIfAvailable(platform: "ios", appVersion: "fixture", credentialContext: .normal(a.lease))
        #expect(CredentialSideEffectURLProtocol.requests.count == 2)
        let tokens = try CredentialSideEffectURLProtocol.bodies.map { body in
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return try #require(json["device_token"] as? String)
        }
        #expect(tokens == ["11", "22"])
        #expect(CredentialSideEffectURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-A" })
    }
}

private final class CredentialSideEffectURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var handler: (@Sendable (URLRequest) async throws -> Void)?
        var requests: [URLRequest] = []
        var bodies: [Data] = []
    }
    private struct Loading { var task: Task<Void, Never>?; var stopped = false }
    private static let state = Mutex(State())
    private let loading = Mutex(Loading())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static var bodies: [Data] { state.withLock { $0.bodies } }
    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async throws -> Void) {
        state.withLock { $0 = State(handler: handler) }
    }
    static func reset() { state.withLock { $0 = State() } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "credential-effects.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let body = Self.readBody(request)
        let handler = Self.state.withLock { $0.requests.append(request); $0.bodies.append(body); return $0.handler }
        let task = Task { @Sendable [self, request, handler] in
            do {
                guard let handler else { throw URLError(.badServerResponse) }
                try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"device_id":"00000000-0000-0000-0000-000000000001","registered_at":0}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
        let stopped = loading.withLock { value in value.task = task; return value.stopped }
        if stopped { task.cancel() }
    }
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { return result }
            result.append(contentsOf: bytes.prefix(count))
        }
    }
    override func stopLoading() {
        let task = loading.withLock { value in value.stopped = true; let task = value.task; value.task = nil; return task }
        task?.cancel()
    }
}
