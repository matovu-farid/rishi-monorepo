import Foundation
import Synchronization
import Testing
@testable import rishi

private final class StagedOwnershipURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, Data)
    private static let handlers = Mutex<[String: Handler]>([:])
    private let running = Mutex<Task<Void, Never>?>(nil)

    static func register(_ handler: @escaping Handler, host: String) {
        handlers.withLock { $0[host] = handler }
    }
    static func remove(host: String) { _ = handlers.withLock { $0.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let task = Task { [self] in
            do {
                guard let url = request.url, let host = url.host,
                      let handler = Self.handlers.withLock({ $0[host] }) else { throw URLError(.unsupportedURL) }
                let (status, data) = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
        running.withLock { $0 = task }
    }
    override func stopLoading() { running.withLock { $0?.cancel(); $0 = nil } }
}

private struct StagedOwnershipTransport {
    let worker: WorkerClient
    let session: URLSession
    let host: String

    init(authority: SessionCredentialAuthority, handler: @escaping StagedOwnershipURLProtocol.Handler) {
        host = "\(UUID().uuidString.lowercased()).credential-stage.test"
        StagedOwnershipURLProtocol.register(handler, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StagedOwnershipURLProtocol.self]
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
        worker = WorkerClient(baseURL: URL(string: "https://\(host)")!, session: session,
                              credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
                              admitCredentialRejection: { _, _ in .stale })
    }

    func close() {
        session.invalidateAndCancel()
        StagedOwnershipURLProtocol.remove(host: host)
    }
}

private struct StagedEntitlementCache: Codable {
    let cachedAt: Date
    let snapshot: EntitlementSnapshot
}

private struct StagedLaunchRefresh: CredentialBoundEntitlementLaunchRefresh {
    let authority: SessionCredentialAuthority
    func usesCredentialAuthority(_ authority: SessionCredentialAuthority) -> Bool { self.authority === authority }
    func refreshOnDeviceEntitlementAtLaunch() async {}
    func refreshOnDeviceEntitlementAtLaunch(credentialContext: CredentialRequestContext) async {}
}

@Suite("Credential entitlement — actual actor/cache publication", .serialized, .timeLimit(.minutes(1)))
struct CredentialEntitlementOwnershipTests {
    @Test("a late A response cannot mutate B resolution/cache; current B publishes normally")
    func lateResponse() async throws {
        let name = "credential-entitlement-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let response = try JSONEncoder().encode(EntitlementSnapshot.trialActive(remainingCredits: 11))
        let requests = Mutex<[String]>([])
        let transport = StagedOwnershipTransport(authority: authority) { request in
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            requests.withLock { $0.append(bearer) }
            if bearer == "Bearer fixture-A" { await gate.suspend() }
            return (200, response)
        }
        defer { transport.close() }
        let service = EntitlementService(workerClient: transport.worker, defaults: defaults, credentialAuthority: authority)
        #expect(await service.bindToUser(userId: "A", lease: a.lease))
        let old = Task { await service.refreshSnapshot(lease: a.lease) }
        await gate.waitUntilEntered()
        let b = try installStagingCredentials("B", authority: authority)
        let fetchedAt = Date(timeIntervalSince1970: 111)
        let cached = EntitlementSnapshot.trialActive(remainingCredits: 8)
        defaults.set(try JSONEncoder().encode(StagedEntitlementCache(cachedAt: fetchedAt, snapshot: cached)), forKey: "billing.entitlement.snapshot.v1.B")
        #expect(await service.bindToUser(userId: "B", lease: b.lease))
        let bytes = try #require(defaults.data(forKey: "billing.entitlement.snapshot.v1.B"))
        let boundCache = try JSONDecoder().decode(StagedEntitlementCache.self, from: bytes)
        #expect(boundCache.cachedAt == fetchedAt)
        #expect(boundCache.snapshot == cached)
        await gate.resume()
        guard case .failure = await old.value else { Issue.record("Stale response was accepted"); return }
        #expect(await service.resolutionNow() == .resolved(cached, fetchedAt: fetchedAt))
        #expect(defaults.data(forKey: "billing.entitlement.snapshot.v1.B") == bytes)
        guard case .success(let fresh) = await service.refreshSnapshot(lease: b.lease) else { Issue.record("Current refresh failed"); return }
        #expect(fresh == .trialActive(remainingCredits: 11))
        #expect(requests.withLock { $0 } == ["Bearer fixture-A", "Bearer fixture-B"])
    }

    @Test("queued A bind, raw-ID setters and old cleanup cannot overwrite reinstalled A")
    func queuedBindAndABA() async throws {
        let name = "credential-entitlement-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let response = try JSONEncoder().encode(EntitlementSnapshot.trialExhausted)
        let transport = StagedOwnershipTransport(authority: authority) { _ in (200, response) }
        defer { transport.close() }
        let service = EntitlementService(workerClient: transport.worker, defaults: defaults, credentialAuthority: authority)
        #expect(await service.bindToUser(userId: "A", lease: a.lease))
        let gate = CredentialStagingGate()
        let queued = Task { await gate.suspend(); return await service.bindToUser(userId: "A", lease: a.lease) }
        await gate.waitUntilEntered()
        let transition = try authority.beginTransition(expected: a.ticket)
        _ = try authority.install(session: Session(token: "B", userId: "B", email: nil), refreshToken: nil, in: transition)
        let newer = try installStagingCredentials("A", authority: authority)
        #expect(await service.bindToUser(userId: "A", lease: newer.lease))
        guard case .success = await service.refreshSnapshot(lease: newer.lease) else { Issue.record("Current refresh failed"); return }
        let resolution = await service.resolutionNow()
        let bytes = defaults.data(forKey: "billing.entitlement.snapshot.v1.A")
        await gate.resume()
        #expect(await queued.value == false)
        #expect(await service.clearCache(in: transition) == false)
        await service.bindToUser(userId: "B")
        await service.clearSnapshotCache(for: "A")
        await service.clearCache()
        await service.setCached(.subscribed)
        #expect(await service.resolutionNow() == resolution)
        #expect(defaults.data(forKey: "billing.entitlement.snapshot.v1.A") == bytes)
        #expect(await service.snapshot() == .unsubscribed)
    }

    @Test("coordinator separates same raw account reinstall from the earlier in-flight owner")
    func coordinatorABA() async throws {
        let name = "credential-entitlement-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        _ = try installStagingCredentials("A", authority: authority)
        let gate = CredentialStagingGate()
        let count = Mutex(0)
        let response = try JSONEncoder().encode(EntitlementSnapshot.trialActive(remainingCredits: 9))
        let transport = StagedOwnershipTransport(authority: authority) { _ in
            let call = count.withLock { $0 += 1; return $0 }
            if call == 1 { await gate.suspend() }
            return (200, response)
        }
        defer { transport.close() }
        let service = EntitlementService(workerClient: transport.worker, defaults: defaults, credentialAuthority: authority)
        let coordinator = try EntitlementRefreshCoordinator(entitlementService: service, launchRefresh: StagedLaunchRefresh(authority: authority), credentialAuthority: authority)
        let old = Task { await coordinator.refreshIfSignedIn() }
        defer { old.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        try Task.checkCancellation()
        _ = try installStagingCredentials("B", authority: authority)
        _ = try installStagingCredentials("A", authority: authority)
        let current = Task { await coordinator.refreshIfSignedIn() }
        defer { current.cancel() }
        await gate.resume()
        guard case .failure? = await old.value else { Issue.record("Old owner succeeded"); return }
        guard case .success(let snapshot)? = await current.value else { Issue.record("New owner did not refresh"); return }
        #expect(snapshot == .trialActive(remainingCredits: 9))
        #expect(count.withLock { $0 } == 2)
    }
}

@MainActor
@Suite("Scoped deletion — transaction-bound cleanup", .serialized, .timeLimit(.minutes(1)))
struct ScopedAccountDeletionTests {
    private func dependencies(_ authority: SessionCredentialAuthority, userID: UUID?) -> AppDependencies {
        AppDependencies(credentialAuthority: authority, userIdBox: UserIdBox(userID), accountGeneration: 7,
                        persistAccountGeneration: { _ in }, credentialCleanup: { _ in })
    }

    @Test("DELETE uses original admission and reservation spans actual consent clear plus awaited sign-out")
    func successfulDeletionReservation() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let deps = dependencies(authority, userID: DerivedUserID.from("A"))
        let consent = InMemoryDataUseConsentStore(credentialAuthority: authority)
        #expect(await consent.bind(to: a.lease))
        #expect(await consent.grant(for: a.lease))
        let requests = Mutex<[String]>([])
        let transport = StagedOwnershipTransport(authority: authority) { request in
            requests.withLock { $0.append(request.value(forHTTPHeaderField: "Authorization") ?? "") }
            return (200, Data("{\"ok\":true}".utf8))
        }
        defer { transport.close() }
        let gate = CredentialStagingGate()
        let coordinator = AccountDeletionCoordinator(
            admittedDeleteServer: { admission in _ = try await transport.worker.send(DeleteUserEndpoint(), credentialContext: admission.requestContext) },
            purgeLocal: { tx in
                guard let transition = tx.credentialTransition else { Issue.record("Missing cleanup transition"); return }
                #expect(await consent.clear(for: transition))
            },
            restoreOwner: { try await deps.restoreCredentialOwnerAfterDeletionFailure($0) },
            isCurrent: { deps.isCurrentCredentialAccountChange($0) },
            beginCleanup: { deps.beginAccountCleanup($0) }, endCleanup: { deps.endAccountCleanup($0) },
            signOut: { tx in await gate.suspend(); try deps.clearCredentialSessionAndIdentity(in: tx) },
            beginChange: { try deps.beginAccountChange(expectedCredentialTicket: a.ticket) }
        )
        let run = Task { try await coordinator.run() }
        await gate.waitUntilEntered()
        #expect(throws: AccountDeletionCoordinatorError.accountChangedDuringDeletion) {
            try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        }
        await gate.resume()
        try await run.value
        #expect(requests.withLock { $0 } == ["Bearer fixture-A"])
        #expect(deps.cachedUserId == nil)
        #expect(await consent.record(for: a.lease) == nil)
        _ = try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
    }

    @Test("late failed DELETE does not restore A after B replaces it")
    func staleFailure() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let deps = try CredentialIdentityFixture(authority: authority, ownerID: DerivedUserID.from("A")).dependencies
        let gate = CredentialStagingGate()
        let transport = StagedOwnershipTransport(authority: authority) { _ in
            await gate.suspend(); return (400, Data("{\"error\":{\"code\":\"invalid_request\",\"message\":\"fixture\"}}".utf8))
        }
        defer { transport.close() }
        let purges = Mutex(0)
        let coordinator = AccountDeletionCoordinator(
            admittedDeleteServer: { admission in _ = try await transport.worker.send(DeleteUserEndpoint(), credentialContext: admission.requestContext) },
            purgeLocal: { _ in purges.withLock { $0 += 1 } },
            restoreOwner: { try await deps.restoreCredentialOwnerAfterDeletionFailure($0) },
            isCurrent: { deps.isCurrentCredentialAccountChange($0) },
            beginCleanup: { deps.beginAccountCleanup($0) }, endCleanup: { deps.endAccountCleanup($0) },
            signOut: { try deps.clearCredentialSessionAndIdentity(in: $0) },
            beginChange: { try deps.beginAccountChange(expectedCredentialTicket: a.ticket) }
        )
        let run = Task { try await coordinator.run() }
        await gate.waitUntilEntered()
        let bTx = try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket())
        let b = try await deps.installCredentialSession(Session(token: "B-token", userId: "B", email: nil), refreshToken: nil, in: bTx)
        await gate.resume()
        do { try await run.value; Issue.record("Expected stale deletion failure") } catch {}
        #expect(try authority.snapshot() == b)
        #expect(deps.cachedUserId == DerivedUserID.from("B"))
        #expect(purges.withLock { $0 } == 0)
    }

    @Test("same-owner DELETE failure restores a fresh lease and local-only purge never deletes")
    func failureAndLocalPurge() async throws {
        enum FixtureFailure: Error { case deletion }
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        let a = try installStagingCredentials("A", authority: authority)
        let deps = dependencies(authority, userID: DerivedUserID.from("A"))
        let deletions = Mutex(0)
        let coordinator = AccountDeletionCoordinator(
            admittedDeleteServer: { _ in deletions.withLock { $0 += 1 }; throw FixtureFailure.deletion },
            purgeLocal: { _ in },
            restoreOwner: { try await deps.restoreCredentialOwnerAfterDeletionFailure($0) },
            isCurrent: { deps.isCurrentCredentialAccountChange($0) },
            beginCleanup: { deps.beginAccountCleanup($0) }, endCleanup: { deps.endAccountCleanup($0) },
            signOut: { try deps.clearCredentialSessionAndIdentity(in: $0) },
            beginChange: { try deps.beginAccountChange(expectedCredentialTicket: authority.attemptTicket()) }
        )
        do { try await coordinator.run(); Issue.record("Expected deletion failure") } catch is FixtureFailure {}
        let restored = try authority.snapshot()
        #expect(restored.lease != a.lease)
        #expect(restored.session.token == a.session.token)
        #expect(deps.cachedUserId == DerivedUserID.from("A"))
        try await coordinator.purgeLocalOnly()
        #expect(deletions.withLock { $0 } == 1)
        #expect(try authority.snapshot().session.token == a.session.token)
        #expect(deps.cachedUserId == DerivedUserID.from("A"))
    }
}
