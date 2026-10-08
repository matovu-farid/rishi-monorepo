import Foundation
import Synchronization
import Testing
@testable import rishi

@MainActor
@Suite("Canonical cutover ownership — isolated storage", .serialized, .timeLimit(.minutes(1)))
struct CredentialLiveCutoverTests {
    @Test("presented consent forwards bind/grant/read/revoke to the actual captured owner")
    func currentConsent() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("opaque-A", authority: authority)
        let store = InMemoryDataUseConsentStore(credentialAuthority: authority)
        let adapter = CredentialBoundDataUseConsentStore(store: store, authority: authority, lease: a.lease)
        let key = DerivedUserID.from(a.lease.rawUserID).uuidString
        await adapter.setCurrentUser(key)
        await adapter.grant(for: key)
        #expect(await adapter.isCurrent(for: key))
        let record = await store.record(for: a.lease)
        #expect(await adapter.record(for: key) == record)
        await adapter.revoke(for: key)
        #expect(await store.record(for: a.lease) == nil)
        #expect(!((await adapter.isCurrent(for: key))))
    }

    @Test("retained consent cannot grant/revoke or rebind B or a new A installation", arguments: ["B", "A"])
    func staleConsent(_ replacement: String) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let store = InMemoryDataUseConsentStore(credentialAuthority: authority)
        let adapter = CredentialBoundDataUseConsentStore(store: store, authority: authority, lease: a.lease)
        let aKey = DerivedUserID.from("A").uuidString
        await adapter.setCurrentUser(aKey); await adapter.grant(for: aKey)
        let b = try installStagingCredentials(replacement, authority: authority)
        #expect(await store.bind(to: b.lease)); #expect(await store.grant(for: b.lease))
        let original = await store.record(for: b.lease)
        await adapter.setCurrentUser(aKey); await adapter.revoke(for: aKey); await adapter.grant(for: aKey)
        #expect(await store.record(for: b.lease) == original)
        #expect(await adapter.record(for: aKey) == nil)
        #expect(try authority.snapshot() == b)
        #expect(a.lease != b.lease)
    }

    @Test("a current consent adapter refuses raw or unrelated UI keys")
    func consentKey() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("opaque-A", authority: authority)
        let store = InMemoryDataUseConsentStore(credentialAuthority: authority)
        #expect(await store.bind(to: a.lease)); #expect(await store.grant(for: a.lease))
        let original = await store.record(for: a.lease)
        let adapter = CredentialBoundDataUseConsentStore(store: store, authority: authority, lease: a.lease)
        await adapter.setCurrentUser("opaque-A"); await adapter.revoke(for: "opaque-A")
        await adapter.grant(for: UUID().uuidString)
        #expect(await store.record(for: a.lease) == original)
        #expect(await adapter.record(for: "opaque-A") == nil)
    }

    @Test("cold and published retirement retain the exact normal lease separately from outgoing DELETE", arguments: [false, true])
    func outgoingNormalLease(_ published: Bool) async throws {
        let storage = CredentialStagingMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let a = try installStagingCredentials("A", authority: authority)
        let consent = InMemoryDataUseConsentStore(credentialAuthority: authority)
        #expect(await consent.bind(to: a.lease)); #expect(await consent.grant(for: a.lease))
        let fixture = try CredentialIdentityFixture(authority: authority, ownerID: published ? DerivedUserID.from("A") : nil,
            cleanup: { transaction in
                #expect(transaction.outgoingNormalCredentialLease == a.lease)
                #expect(transaction.capturedLocalAccountID == (published ? DerivedUserID.from("A") : nil))
                #expect(transaction.outgoingAccountID == DerivedUserID.from("A"))
                guard let transition = transaction.credentialTransition else { Issue.record("Missing captured transition"); return }
                #expect(await consent.clear(for: transition))
            })
        let permit = AccountMutationPermit(ownerID: DerivedUserID.from("A"), accountGeneration: 17)
        try await fixture.mutations.activate(permit)
        let tx = try fixture.dependencies.beginAccountChange(expectedCredentialTicket: a.ticket, rejection: a.rejectionContext)
        let deletion = try #require(tx.deletionAdmission)
        #expect(deletion.outgoingLease.installationID == a.lease.installationID)
        #expect(deletion.outgoingLease.rawUserID == a.lease.rawUserID)
        #expect(deletion.outgoingLease.epoch == a.lease.epoch &+ 1)
        #expect(tx.outgoingNormalCredentialLease == a.lease)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try authority.snapshot(for: .normal(a.lease)) }
        let cleanup = try #require(fixture.dependencies.retireCredentialAccount(tx))
        await cleanup.value
        await fixture.assertDenied(permit)
        #expect(fixture.dependencies.cachedUserId == nil)
        #expect(fixture.dependencies.pendingAccountChange == nil)
        let retainedTransition = try #require(tx.credentialTransition)
        let projection = try #require(fixture.dependencies.credentialRetirementProjection(for: retainedTransition))
        if case .completed = projection.status {} else { Issue.record("Owned retirement did not complete") }
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try authority.snapshot() }
    }

    private struct Reply: Decodable, Sendable { let ok: Bool }
    private struct Ping: WorkerEndpoint {
        typealias Response = Reply
        var method: HTTPMethod = .GET
        var path = "/ping"
        var requiresDataUseConsent = false
    }
    private struct Audio: WorkerStreamingEndpoint {
        var method: HTTPMethod = .POST
        var path = "/audio"
        var requiresDataUseConsent = false
    }

    @Test("public static-token transports do not select global refresh after 401", arguments: ["send", "binary", "stream"])
    func static401(_ transport: String) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CutoverUnauthorizedProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        CutoverUnauthorizedProtocol.reset()
        defer { session.invalidateAndCancel(); CutoverUnauthorizedProtocol.reset() }
        let worker = WorkerClient(baseURL: URL(string: "https://cutover.example.invalid")!, session: session,
            tokenProvider: StaticTokenProvider("fixture-static"), dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        do {
            switch transport {
            case "send": _ = try await worker.send(Ping())
            case "binary": _ = try await worker.downloadData(Audio())
            default:
                let chunks = await worker.stream(Audio())
                for try await _ in chunks {}
            }
            Issue.record("Unauthorized static-token request accepted")
        } catch { #expect(error as? CredentialAuthenticationFailure == .reauthenticationRequired) }
        #expect(CutoverUnauthorizedProtocol.paths == [transport == "send" ? "/ping" : "/audio"])
    }

    @Test("public static-token explicit refresh fails without transport or storage")
    func explicitStaticRefresh() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CutoverUnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        CutoverUnauthorizedProtocol.reset()
        defer { session.invalidateAndCancel(); CutoverUnauthorizedProtocol.reset() }
        let worker = WorkerClient(baseURL: URL(string: "https://cutover.example.invalid")!, session: session,
            tokenProvider: StaticTokenProvider("fixture-static"), dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        do { try await worker.refreshAuthentication(); Issue.record("Unscoped refresh accepted") }
        catch { #expect(error as? CredentialAuthenticationFailure == .reauthenticationRequired) }
        #expect(CutoverUnauthorizedProtocol.paths.isEmpty)
    }
}

private final class CutoverUnauthorizedProtocol: URLProtocol, @unchecked Sendable {
    private static let requests = Mutex<[String]>([])
    static var paths: [String] { requests.withLock { $0 } }
    static func reset() { requests.withLock { $0.removeAll() } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cutover.example.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.withLock { $0.append(request.url!.path) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
