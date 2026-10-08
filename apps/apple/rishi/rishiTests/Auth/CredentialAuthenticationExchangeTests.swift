import Foundation
import Synchronization
import Testing
@testable import rishi

@Suite("Anonymous authentication exchanges — injected ticket ownership", .serialized, .timeLimit(.minutes(1)))
struct CredentialAuthenticationExchangeTests {
    private func makeClient(_ authority: SessionCredentialAuthority, admissions: CredentialExchangeCounter, configuredHeader: String? = nil) -> (WorkerClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialExchangeURLProtocol.self]
        if let configuredHeader { configuration.httpAdditionalHeaders = [configuredHeader: "fixture-A-secret"] }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        let worker = WorkerClient(baseURL: URL(string: "https://authentication-exchange.example.invalid")!, session: session,
            credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
            admitCredentialRejection: { _, _ in admissions.record(); return .stale })
        return (worker, session)
    }
    private func endpoint() -> EmailPasswordSignInEndpoint {
        .init(email: "fixture@example.invalid", password: "fixture-password")
    }
    private func success() -> CredentialExchangeURLProtocol.Response {
        .init(status: 200, body: Data(#"{"token":"opaque-response-token","user":{"id":"anonymous-user","email":"fixture@example.invalid"}}"#.utf8))
    }

    @Test("signed-in and unloaded signed-out exchanges have no bearer/cookies/refresh or credential writes",
          arguments: [false, true], ["success", "coded401", "untyped401"])
    func anonymousExchange(_ signedIn: Bool, _ responseKind: String) async throws {
        let storage = CredentialExchangeStorage()
        let authority = SessionCredentialAuthority(persistence: storage)
        let original = signedIn ? try installStagingCredentials("A", authority: authority) : nil
        let ticket = authority.attemptTicket()
        let bytes = storage.bytes
        let reads = storage.reads
        let writes = storage.writes
        let admissions = CredentialExchangeCounter()
        CredentialExchangeURLProtocol.setHandler { _ in
            responseKind == "success" ? success() : .init(status: 401, body: responseKind == "coded401" ? Data(#"{"error":{"code":"INVALID_REFRESH_TOKEN","message":"fixture"}}"#.utf8) : Data())
        }
        let (worker, session) = makeClient(authority, admissions: admissions)
        defer { session.invalidateAndCancel(); CredentialExchangeURLProtocol.reset() }
        if responseKind == "success" {
            let reply = try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: ticket)
            #expect(reply.token == "opaque-response-token")
            #expect(reply.user.id == "anonymous-user")
        } else {
            do { _ = try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: ticket); Issue.record("Unauthorized exchange accepted") }
            catch { #expect(error as? CredentialAuthenticationFailure == .reauthenticationRequired) }
        }
        let requests = CredentialExchangeURLProtocol.requests
        #expect(requests.count == 1)
        #expect(requests.allSatisfy { $0.url?.path == "/api/auth/sign-in/email" && $0.httpMethod == "POST" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Cookie") == nil && !$0.httpShouldHandleCookies })
        #expect(admissions.count == 0)
        #expect(authority.attemptTicket() == ticket)
        #expect(storage.bytes == bytes && storage.reads == reads && storage.writes == writes)
        if let original { #expect(try authority.snapshot() == original) }
        else { #expect(storage.bytes == nil && storage.reads == 0 && storage.writes == 0) }
    }

    @Test("captured anonymous ticket rejects B before transport and after a late response", arguments: [false, true])
    func replacedAttempt(_ afterSend: Bool) async throws {
        let storage = CredentialExchangeStorage()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        CredentialExchangeURLProtocol.setHandler { _ in await gate.suspend(); return success() }
        let admissions = CredentialExchangeCounter()
        let (worker, session) = makeClient(authority, admissions: admissions)
        defer { session.invalidateAndCancel(); CredentialExchangeURLProtocol.reset(); Task { await gate.resume() } }
        let attempt: Task<EmailPasswordSignInEndpoint.Response, Error>?
        if afterSend {
            attempt = Task { try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: a.ticket) }
            await gate.waitUntilEntered()
        } else { attempt = nil }
        defer { attempt?.cancel(); Task { await gate.resume() } }
        let b = try installStagingCredentials("B", authority: authority)
        let bytes = storage.bytes
        await gate.resume()
        do {
            if let attempt { _ = try await attempt.value }
            else { _ = try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: a.ticket) }
            Issue.record("Replaced anonymous attempt accepted")
        } catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        #expect(CredentialExchangeURLProtocol.requests.count == (afterSend ? 1 : 0))
        #expect(CredentialExchangeURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(try authority.snapshot() == b)
        #expect(storage.bytes == bytes)
        #expect(admissions.count == 0)
    }

    @Test("same-lease token rotation does not grant an anonymous exchange credential-write authority")
    func concurrentRefreshCAS() async throws {
        let storage = CredentialExchangeStorage()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        CredentialExchangeURLProtocol.setHandler { _ in await gate.suspend(); return success() }
        let admissions = CredentialExchangeCounter()
        let (worker, session) = makeClient(authority, admissions: admissions)
        defer { session.invalidateAndCancel(); CredentialExchangeURLProtocol.reset(); Task { await gate.resume() } }
        let attempt = Task { try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: a.ticket) }
        defer { attempt.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        let rotated = try authority.commitRefresh(accessToken: "fresh-A", refreshToken: "fresh-refresh-A",
            issuedAt: Date(timeIntervalSince1970: 10), expected: a)
        let bytes = storage.bytes
        let writes = storage.writes
        await gate.resume()
        let reply = try await attempt.value
        #expect(reply.token == "opaque-response-token")
        #expect(try authority.snapshot() == rotated)
        #expect(storage.bytes == bytes && storage.writes == writes)
        #expect(CredentialExchangeURLProtocol.requests.count == 1)
        #expect(CredentialExchangeURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(admissions.count == 0)
    }

    @Test("anonymous retry checks its original ticket and never retries as B")
    func retryAfterReplacement() async throws {
        let storage = CredentialExchangeStorage()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let bSnapshot = Mutex<CredentialSnapshot?>(nil)
        CredentialExchangeURLProtocol.setHandler { _ in
            let b = try installStagingCredentials("B", authority: authority)
            bSnapshot.withLock { $0 = b }
            throw URLError(.timedOut)
        }
        let admissions = CredentialExchangeCounter()
        let (worker, session) = makeClient(authority, admissions: admissions)
        defer { session.invalidateAndCancel(); CredentialExchangeURLProtocol.reset() }
        do { _ = try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: a.ticket); Issue.record("Replaced retry accepted") }
        catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        let b = try #require(bSnapshot.withLock { $0 })
        #expect(try authority.snapshot() == b)
        #expect(CredentialExchangeURLProtocol.requests.count == 1)
        #expect(CredentialExchangeURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(admissions.count == 0)
    }

    @Test("cancelled authentication cannot issue or deliver an anonymous request", arguments: [false, true])
    func cancellation(_ afterSend: Bool) async throws {
        let storage = CredentialExchangeStorage()
        let authority = SessionCredentialAuthority(persistence: storage)
        let ticket = authority.attemptTicket()
        let gate = CredentialStagingGate()
        CredentialExchangeURLProtocol.setHandler { _ in await gate.suspend(); return success() }
        let admissions = CredentialExchangeCounter()
        let (worker, session) = makeClient(authority, admissions: admissions)
        defer { session.invalidateAndCancel(); CredentialExchangeURLProtocol.reset(); Task { await gate.resume() } }
        let start = CredentialStagingGate()
        let task = Task {
            if !afterSend { await start.suspend() }
            return try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: ticket)
        }
        defer { task.cancel(); Task { await start.resume(); await gate.resume() } }
        if afterSend { await gate.waitUntilEntered() } else { await start.waitUntilEntered() }
        task.cancel(); await start.resume(); await gate.resume()
        do { _ = try await task.value; Issue.record("Cancelled exchange accepted") }
        catch {
            if error is CancellationError { }
            else if case .networkFailure(let failure)? = error as? RishiError {
                #expect(failure.code == .cancelled)
            } else { Issue.record("Unexpected cancellation error: \(error)") }
        }
        #expect(CredentialExchangeURLProtocol.requests.count == (afterSend ? 1 : 0))
        #expect(storage.bytes == nil && storage.reads == 0 && storage.writes == 0)
        #expect(admissions.count == 0)
    }

    @Test("configured bearer or cookie headers reject authentication before transport", arguments: ["aUtHoRiZaTiOn", "cOoKiE"])
    func configuredCredentials(_ header: String) async throws {
        let storage = CredentialExchangeStorage()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let bytes = storage.bytes
        let writes = storage.writes
        let reads = storage.reads
        let admissions = CredentialExchangeCounter()
        let (worker, session) = makeClient(authority, admissions: admissions, configuredHeader: header)
        defer { session.invalidateAndCancel(); CredentialExchangeURLProtocol.reset() }
        do { _ = try await worker.sendAuthentication(endpoint(), expectedCredentialTicket: a.ticket); Issue.record("Configured credentials accepted") }
        catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        #expect(CredentialExchangeURLProtocol.requests.isEmpty)
        #expect(storage.bytes == bytes && storage.reads == reads && storage.writes == writes)
        #expect(admissions.count == 0)
        #expect(try authority.snapshot() == a)
    }

    @Test("authentication entry cannot anonymously send a consent-requiring endpoint")
    func refusesProtectedEndpoint() async throws {
        struct Protected: WorkerEndpoint {
            typealias Response = OkResponse
            let method = HTTPMethod.POST
            let path = "/private"
            let requiresDataUseConsent = true
        }
        let storage = CredentialExchangeStorage()
        let authority = SessionCredentialAuthority(persistence: storage)
        let admissions = CredentialExchangeCounter()
        let (worker, session) = makeClient(authority, admissions: admissions)
        defer { session.invalidateAndCancel(); CredentialExchangeURLProtocol.reset() }
        do { _ = try await worker.sendAuthentication(Protected(), expectedCredentialTicket: authority.attemptTicket()); Issue.record("Protected endpoint sent anonymously") }
        catch { #expect(error as? CredentialAuthenticationFailure == .accountChanged) }
        #expect(CredentialExchangeURLProtocol.requests.isEmpty)
        #expect(storage.reads == 0 && storage.writes == 0)
    }
}

private final class CredentialExchangeCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func record() { value.withLock { $0 += 1 } }
}

private final class CredentialExchangeStorage: SessionCredentialPersistence {
    private struct State { var data: Data?; var reads = 0; var writes = 0 }
    private let state = Mutex(State())
    var bytes: Data? { state.withLock { $0.data } }
    var reads: Int { state.withLock { $0.reads } }
    var writes: Int { state.withLock { $0.writes } }
    func readCanonical() throws -> Data? { state.withLock { $0.reads += 1; return $0.data } }
    func readLegacy() throws -> LegacyCredentials {
        state.withLock { $0.reads += 1 }
        return .init(accessToken: nil, refreshToken: nil, userID: nil)
    }
    func removeLegacy() {}
    func writeCanonical(_ data: Data) throws { state.withLock { $0.writes += 1; $0.data = data } }
}

private final class CredentialExchangeURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { let status: Int; let body: Data }
    private struct State { var handler: (@Sendable (URLRequest) async throws -> Response)?; var requests: [URLRequest] = [] }
    private struct Loading { var task: Task<Void, Never>?; var stopped = false }
    private static let state = Mutex(State())
    private let loading = Mutex(Loading())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async throws -> Response) { state.withLock { $0 = State(handler: handler) } }
    static func reset() { state.withLock { $0 = State() } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "authentication-exchange.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let handler = Self.state.withLock { $0.requests.append(request); return $0.handler }
        let task = Task { @Sendable [self, request, handler] in
            do {
                guard let handler else { throw URLError(.badServerResponse) }
                let result = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json", "Set-Cookie":"fixture-response=opaque; Path=/"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: result.body)
                client?.urlProtocolDidFinishLoading(self)
            } catch { if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) } }
        }
        let stopped = loading.withLock { $0.task = task; return $0.stopped }
        if stopped { task.cancel() }
    }
    override func stopLoading() {
        let task = loading.withLock { value in value.stopped = true; let task = value.task; value.task = nil; return task }
        task?.cancel()
    }
}
