import Foundation
import Synchronization
import Testing
@testable import rishi

@Suite("Inactive shared and voice credential adapters", .serialized, .timeLimit(.minutes(1)))
struct SessionAdapterCredentialOwnershipTests {
    private let baseURL = URL(string: "https://adapters.example.invalid")!

    private func worker(_ authority: SessionCredentialAuthority, session: URLSession,
                        admission: @escaping @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission = { _, _ in .stale }) -> WorkerClient {
        WorkerClient(baseURL: baseURL, session: session, credentialAuthority: authority,
                     dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
                     admitCredentialRejection: admission)
    }
    private func shared(_ authority: SessionCredentialAuthority, lease: CredentialLease, session: URLSession,
                        admission: @escaping @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission = { _, _ in .stale }) throws -> SharedReadingAPI {
        try SharedReadingAPI(baseURL: baseURL, session: session, credentialAuthority: authority,
                             workerClient: worker(authority, session: session, admission: admission), credentialContext: .normal(lease))
    }
    private func voice(_ authority: SessionCredentialAuthority, lease: CredentialLease, session: URLSession) throws -> VoiceSessionAPIClient {
        try VoiceSessionAPIClient(workerClient: worker(authority, session: session), credentialAuthority: authority,
                                  credentialContext: .normal(lease), baseURL: baseURL, session: session,
                                  dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
    }
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdapterCredentialURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }
    private func install(_ owner: String, in authority: SessionCredentialAuthority, refresh: Bool = true) throws -> CredentialSnapshot {
        let transaction = try authority.beginTransition(expected: authority.attemptTicket())
        return try authority.install(session: Session(token: "access-\(owner)", userId: owner, email: "\(owner)@example.invalid",
                                                      issuedAt: Date(timeIntervalSince1970: 1), expiresAt: nil),
                                     refreshToken: refresh ? "refresh-\(owner)" : nil, in: transaction)
    }
    private func refreshReply() -> AdapterCredentialURLProtocol.Response {
        .init(200, #"{"accessToken":"fresh-A","refreshToken":"fresh-refresh-A","userId":"A"}"#)
    }
    private func expectCode(_ code: SharedReadingErrorCode, operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected shared admission failure") }
        catch let error as SharedReadingError { #expect(error.code == code) }
        catch { Issue.record("Unexpected error type: \(type(of: error))") }
    }

    @Test("Scoped adapter construction neither reads storage nor accepts deletion admission")
    func passiveConstruction() throws {
        let storage = AdapterCredentialMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let lease = CredentialLease(installationID: UUID(), epoch: 0, rawUserID: "A")
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        _ = try shared(authority, lease: lease, session: session)
        _ = try voice(authority, lease: lease, session: session)
        #expect(storage.readCount == 0)
        let deletion = CredentialRequestContext.deletion(transactionID: UUID(), outgoingLease: lease)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try SharedReadingAPI(baseURL: baseURL, session: session, credentialAuthority: authority,
                                 workerClient: worker(authority, session: session), credentialContext: deletion)
        }
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try VoiceSessionAPIClient(workerClient: worker(authority, session: session), credentialAuthority: authority,
                                      credentialContext: deletion, baseURL: baseURL, session: session,
                                      dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        }
        #expect(storage.readCount == 0)
        #expect(AdapterCredentialURLProtocol.requests.isEmpty)
    }

    @Test("Required scoped adapters reject a different Worker authority before transport")
    func mismatchedWorkerAuthority() throws {
        let storageA = AdapterCredentialMemoryPersistence()
        let storageB = AdapterCredentialMemoryPersistence()
        let authorityA = SessionCredentialAuthority(persistence: storageA)
        let authorityB = SessionCredentialAuthority(persistence: storageB)
        let lease = CredentialLease(installationID: UUID(), epoch: 0, rawUserID: "A")
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        let wrongWorker = worker(authorityB, session: session)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try SharedReadingAPI(baseURL: baseURL, session: session, credentialAuthority: authorityA,
                                 workerClient: wrongWorker, credentialContext: .normal(lease))
        }
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try VoiceSessionAPIClient(workerClient: wrongWorker, credentialAuthority: authorityA, credentialContext: .normal(lease),
                                      baseURL: baseURL, session: session, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        }
        #expect(storageA.readCount == 0)
        #expect(storageB.readCount == 0)
        #expect(AdapterCredentialURLProtocol.requests.isEmpty)
    }

    @Test("Scoped payload-only creation paths cannot discard a cleanup receipt")
    func payloadOnlyCreationRejected() async throws {
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority)
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        let shared = try shared(authority, lease: a.lease, session: session)
        let voice = try voice(authority, lease: a.lease, session: session)
        await expectCode(.accountChanged) { _ = try await shared.redeem(token: "fixture-invite") }
        await expectCode(.accountChanged) { _ = try await shared.rejoin(sessionId: "room", contentHash: "hash") }
        await expectCode(.authRequired) { _ = try await shared.refreshBearerToken() }
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await voice.startSession(language: nil, bookContext: nil) }
        #expect(AdapterCredentialURLProtocol.requests.isEmpty)
        #expect(try authority.snapshot() == a)
    }

    @Test("Shared retry retains request identity and refreshes only the captured lease")
    func sharedRefresh() async throws {
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority)
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        AdapterCredentialURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { return refreshReply() }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A"
                ? .init(401) : .init(200, #"{"sessions":[]}"#)
        }
        let api = try shared(authority, lease: a.lease, session: session)
        #expect(try await api.activeSessions().sessions.isEmpty)
        let requests = AdapterCredentialURLProtocol.requests
        #expect(requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer access-A", nil, "Bearer fresh-A"])
        #expect(requests[0].value(forHTTPHeaderField: "X-Rishi-Request-ID") == requests[2].value(forHTTPHeaderField: "X-Rishi-Request-ID"))
        #expect(requests.allSatisfy { !$0.httpShouldHandleCookies })
        #expect(try authority.snapshot().lease == a.lease)
    }

    @Test("Legacy shared construction preserves its existing cookie policy")
    func legacyCookiePolicy() async throws {
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        AdapterCredentialURLProtocol.setHandler { _ in .init(200, #"{"sessions":[]}"#) }
        let api = SharedReadingAPI(baseURL: baseURL, session: session, tokenProvider: StaticTokenProvider("legacy"))
        #expect(try await api.activeSessions().sessions.isEmpty)
        #expect(AdapterCredentialURLProtocol.requests.count == 1)
        #expect(AdapterCredentialURLProtocol.requests[0].httpShouldHandleCookies)
    }

    @Test("An old shared401 stops before refreshing a replacement installation", arguments: ["B", "A"])
    func sharedStaleUnauthorized(_ replacement: String) async throws {
        let gate = AdapterCredentialGate()
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority)
        let session = session()
        let api = try shared(authority, lease: a.lease, session: session)
        AdapterCredentialURLProtocol.setHandler { _ in await gate.pause(); return .init(401) }
        let old = Task { try await api.activeSessions() }
        defer { old.cancel(); gate.open(); session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        await gate.waitForEntry()
        let b = try install(replacement, in: authority)
        gate.open()
        await expectCode(.accountChanged) { _ = try await old.value }
        #expect(AdapterCredentialURLProtocol.requests.count == 1)
        #expect(try authority.snapshot() == b)
        #expect(SharedReadingReconnectDecision.forError(.accountChanged) == .stop(.accountChanged))
    }

    @Test("Shared late admission retains successful original-bearer cleanup", arguments: [
        ("redeem", false), ("redeem", true), ("rejoin", false), ("rejoin", true)
    ])
    func sharedLateAdmission(_ kind: String, _ rotates: Bool) async throws {
        let gate = AdapterCredentialGate()
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority)
        let session = session()
        let api = try shared(authority, lease: a.lease, session: session)
        AdapterCredentialURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { return refreshReply() }
            if request.url?.path.hasSuffix("/leave") == true {
                return .init(200, #"{"sessionId":"room","status":"active","roomEpoch":1,"controllerGeneration":1,"controllerUserId":"A"}"#)
            }
            if rotates, request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" { return .init(401) }
            await gate.pause()
            return kind == "redeem"
                ? .init(200, #"{"inviteId":"invite","sessionId":"room","book":{"bookId":"book","contentHash":"hash","format":"epub","fileSize":1},"status":"active","redemptionId":"redemption"}"#)
                : .init(200, #"{"admissionTicket":"ticket","wsUrl":"wss://adapters.example.invalid/room","roomEpoch":1,"connectionGeneration":1,"status":"active"}"#)
        }
        let old = Task {
            if kind == "redeem" { return try await api.redeemWithAccountBoundCleanup(token: "invite").cleanupAPI }
            return try await api.rejoinWithAccountBoundCleanup(sessionId: "room", contentHash: "hash").cleanupAPI
        }
        defer { old.cancel(); gate.open(); session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        await gate.waitForEntry()
        let b = try install("B", in: authority)
        gate.open()
        let cleanup = try await old.value
        _ = try await cleanup.leave(sessionId: "room", deliberate: false)
        #expect(AdapterCredentialURLProtocol.requests.allSatisfy { !$0.httpShouldHandleCookies })
        await expectCode(.authRequired) { _ = try await cleanup.refreshBearerToken() }
        #expect(AdapterCredentialURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == (rotates ? "Bearer fresh-A" : "Bearer access-A"))
        #expect(AdapterCredentialURLProtocol.requests.filter { $0.url?.path == "/auth/refresh" }.count == (rotates ? 1 : 0))
        #expect(try authority.snapshot() == b)
    }

    @Test("Socket refresh reuses same-lease HTTP rotation and refuses a new account")
    func boundSocketRefresh() async throws {
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority)
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        AdapterCredentialURLProtocol.setHandler { request in
            request.url?.path == "/auth/refresh" ? refreshReply() : .init(200, #"{"sessions":[]}"#)
        }
        let api = try shared(authority, lease: a.lease, session: session)
        #expect(try await api.bearerToken() == "access-A")
        _ = try await worker(authority, session: session).refreshAuthentication(credentialContext: .normal(a.lease), failed: a.rejectionContext)
        #expect(try await api.refreshBearerToken() == "fresh-A")
        #expect(AdapterCredentialURLProtocol.requests.count == 1)
        let b = try install("B", in: authority)
        await expectCode(.accountChanged) { _ = try await api.refreshBearerToken() }
        await expectCode(.accountChanged) { _ = try await api.bearerToken() }
        #expect(AdapterCredentialURLProtocol.requests.count == 1)
        #expect(try authority.snapshot() == b)
    }

    @Test("Shared typed refresh failures preserve credentials and domain actions", arguments: ["opaque", "transient", "ambiguous", "definitive", "stale"])
    func sharedRefreshFailureMapping(_ kind: String) async throws {
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority, refresh: kind != "opaque")
        let admissions = Mutex<[CredentialRejectionContext]>([])
        let retirementID = UUID()
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        AdapterCredentialURLProtocol.setHandler { request in
            if request.url?.path != "/auth/refresh" { return .init(401) }
            if kind == "transient" { return .init(503) }
            if kind == "ambiguous" { return .init(401) }
            return .init(401, #"{"error":"rejected","code":"INVALID_REFRESH_TOKEN"}"#)
        }
        let api = try shared(authority, lease: a.lease, session: session, admission: { code, context in
            #expect(code == .invalidRefreshToken)
            admissions.withLock { $0.append(context) }
            return kind == "stale" ? .stale : .admitted(retirementID)
        })
        let expected: SharedReadingErrorCode = kind == "transient" ? .serviceUnavailable : (kind == "stale" ? .accountChanged : .authRequired)
        await expectCode(expected) { _ = try await api.activeSessions() }
        #expect(admissions.withLock { $0 } == (["definitive", "stale"].contains(kind) ? [a.rejectionContext] : []))
        #expect(try authority.snapshot() == a)
        #expect(AdapterCredentialURLProtocol.requests.count == (kind == "opaque" ? 1 : 2))
    }

    @Test("Voice late receipt retries only its own actual successful bearer", arguments: [false, true])
    func voiceLateReceipt(_ rotates: Bool) async throws {
        let gate = AdapterCredentialGate()
        let ends = Mutex(0)
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority)
        let session = session()
        let api = try voice(authority, lease: a.lease, session: session)
        AdapterCredentialURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { return refreshReply() }
            if request.url?.path.hasSuffix("/end") == true {
                return ends.withLock { $0 += 1; return $0 } == 1 ? .init(401) : .init(200, #"{"ok":true}"#)
            }
            if rotates, request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" { return .init(401) }
            await gate.pause()
            return .init(200, #"{"rishiSessionId":"voice-A","nonce":"nonce","clientSecret":"fixture-secret","capIntervals":1,"realtimeModel":"fixture"}"#)
        }
        let old = Task { try await api.startSessionWithReceipt(language: nil, bookContext: nil) }
        defer { old.cancel(); gate.open(); session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        await gate.waitForEntry()
        let b = try install("B", in: authority)
        gate.open()
        let receipt = try await old.value
        #expect(receipt.lease == a.lease)
        #expect(receipt.started.rishiSessionId == "voice-A")
        await #expect(throws: CredentialAuthenticationFailure.reauthenticationRequired) { try await receipt.endSpecificSession() }
        #expect(ends.withLock { $0 } == 1)
        try await receipt.endSpecificSession()
        let endRequests = AdapterCredentialURLProtocol.requests.filter { $0.url?.path.hasSuffix("/end") == true }
        #expect(endRequests.map { $0.url?.path } == ["/api/voice-sessions/voice-A/end", "/api/voice-sessions/voice-A/end"])
        #expect(endRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == Array(repeating: rotates ? "Bearer fresh-A" : "Bearer access-A", count: 2))
        #expect(endRequests.allSatisfy { !$0.httpShouldHandleCookies })
        #expect(AdapterCredentialURLProtocol.requests.filter { $0.url?.path == "/auth/refresh" }.count == (rotates ? 1 : 0))
        #expect(try authority.snapshot() == b)
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await api.registerCall(rishiSessionId: "voice-A", callId: "call", nonce: "nonce") }
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await api.endSession(rishiSessionId: "voice-A") }
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await api.endActiveSessionIfAny() }
        #expect(AdapterCredentialURLProtocol.requests.count == (rotates ? 5 : 3))
    }

    @Test("Receipt cleanup treats an already-terminal row as delivered", arguments: [404, 409])
    func alreadyTerminalReceipt(_ status: Int) async throws {
        let authority = SessionCredentialAuthority(persistence: AdapterCredentialMemoryPersistence())
        let a = try install("A", in: authority)
        let session = session()
        defer { session.invalidateAndCancel(); AdapterCredentialURLProtocol.reset() }
        AdapterCredentialURLProtocol.setHandler { request in
            request.url?.path.hasSuffix("/end") == true
                ? .init(status, #"{"code":"NO_ACTIVE_VOICE_SESSION","error":"ended"}"#)
                : .init(200, #"{"rishiSessionId":"voice-A","nonce":"nonce","clientSecret":"fixture-secret","capIntervals":1,"realtimeModel":"fixture"}"#)
        }
        let receipt = try await voice(authority, lease: a.lease, session: session).startSessionWithReceipt(language: nil, bookContext: nil)
        try await receipt.endSpecificSession()
        #expect(AdapterCredentialURLProtocol.requests.count == 2)
    }
}

private final class AdapterCredentialMemoryPersistence: SessionCredentialPersistence, Sendable {
    private struct State { var data: Data?; var reads = 0 }
    private let state = Mutex(State())
    var readCount: Int { state.withLock { $0.reads } }
    func readCanonical() -> Data? { state.withLock { $0.reads += 1; return $0.data } }
    func writeCanonical(_ data: Data) { state.withLock { $0.data = data } }
    func readLegacy() -> LegacyCredentials { .init(accessToken: nil, refreshToken: nil, userID: nil) }
    func removeLegacy() {}
}

private final class AdapterCredentialGate: Sendable {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Never> }
    private struct State { var entered = false; var open = false; var paused: [Waiter] = []; var observers: [Waiter] = [] }
    private let state = Mutex(State())
    func pause() async { await wait(observing: false) }
    func waitForEntry() async { await wait(observing: true) }
    private func wait(observing: Bool) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock { state in
                    if observing {
                        if state.entered || Task.isCancelled { continuation.resume() }
                        else { state.observers.append(.init(id: id, continuation: continuation)) }
                    } else {
                        state.entered = true
                        state.observers.forEach { $0.continuation.resume() }; state.observers.removeAll()
                        if state.open || Task.isCancelled { continuation.resume() }
                        else { state.paused.append(.init(id: id, continuation: continuation)) }
                    }
                }
            }
        } onCancel: {
            self.state.withLock { state in
                if let index = state.paused.firstIndex(where: { $0.id == id }) { state.paused.remove(at: index).continuation.resume() }
                if let index = state.observers.firstIndex(where: { $0.id == id }) { state.observers.remove(at: index).continuation.resume() }
            }
        }
    }
    func open() {
        state.withLock { state in
            state.open = true; state.entered = true
            state.paused.forEach { $0.continuation.resume() }; state.paused.removeAll()
            state.observers.forEach { $0.continuation.resume() }; state.observers.removeAll()
        }
    }
}

private final class AdapterCredentialURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let data: Data
        init(_ status: Int, _ json: String = "{}") { self.status = status; self.data = Data(json.utf8) }
    }
    private struct State { var handler: (@Sendable (URLRequest) async throws -> Response)?; var requests: [URLRequest] = [] }
    private static let state = Mutex(State())
    private let loadingTask = Mutex<Task<Void, Never>?>(nil)
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async throws -> Response) { state.withLock { $0 = State(handler: handler) } }
    static func reset() { state.withLock { $0 = State() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let handler = Self.state.withLock { state in state.requests.append(request); return state.handler }
        let task = Task { @Sendable [self, request, handler] in
            do {
                guard let handler else { throw URLError(.badServerResponse) }
                let reply = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) } }
        }
        loadingTask.withLock { $0 = task }
    }
    override func stopLoading() { loadingTask.withLock { $0?.cancel(); $0 = nil } }
}
