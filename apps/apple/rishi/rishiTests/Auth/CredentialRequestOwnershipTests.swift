import Foundation
import Synchronization
import Testing
@testable import rishi

@Suite("Scoped credential requests — isolated transport", .serialized, .timeLimit(.minutes(1)))
struct CredentialRequestOwnershipTests {
    private struct Reply: Decodable, Sendable, Equatable { let ok: Bool }
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

    private func install(_ owner: String, in authority: SessionCredentialAuthority, refresh: Bool = true) throws -> CredentialSnapshot {
        let transition = try authority.beginTransition(expected: authority.attemptTicket())
        return try authority.install(
            session: Session(token: "access-\(owner)", userId: owner, email: "\(owner)@example.invalid",
                             issuedAt: Date(timeIntervalSince1970: 1), expiresAt: Date(timeIntervalSince1970: 2)),
            refreshToken: refresh ? "refresh-\(owner)" : nil, in: transition
        )
    }

    private func makeClient(
        _ authority: SessionCredentialAuthority,
        consent: any WorkerDataUseConsentProvider = AlwaysAllowWorkerDataUseConsentProvider(),
        admission: @escaping @Sendable (CredentialRejectionCode, CredentialRejectionContext) async -> CredentialRetirementAdmission = { _, _ in .stale }
    ) -> (WorkerClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CredentialRequestURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        return (WorkerClient(baseURL: URL(string: "https://credentials.example.invalid")!, session: session,
                             credentialAuthority: authority, dataUseConsentProvider: consent,
                             admitCredentialRejection: admission), session)
    }

    private func success() -> CredentialRequestURLProtocol.Response {
        .init(status: 200, body: Data(#"{"ok":true}"#.utf8))
    }

    private func refreshed(_ owner: String = "A") -> CredentialRequestURLProtocol.Response {
        .init(status: 200, body: Data("{\"accessToken\":\"fresh-\(owner)\",\"refreshToken\":\"fresh-refresh-\(owner)\",\"userId\":\"\(owner)\"}".utf8))
    }

    @Test("Scoped construction does not read or migrate its injected storage")
    func passiveConstruction() throws {
        let storage = CredentialRequestMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let (_, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        #expect(storage.readCount == 0)
        #expect(storage.bytes == nil)
        #expect(CredentialRequestURLProtocol.requests.isEmpty)
    }

    @Test("Refresh retries with the same lease and fresh metadata")
    func refreshAndRetry() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let original = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { return refreshed() }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A"
                ? .init(status: 401) : success()
        }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        #expect(try await client.send(Ping()) == Reply(ok: true))
        let current = try authority.snapshot()
        #expect(current.lease == original.lease)
        #expect(current.tokenRevision == 1)
        #expect(current.session.email == original.session.email)
        #expect(current.session.expiresAt == nil)
        #expect(CredentialRequestURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
                == ["Bearer access-A", nil, "Bearer fresh-A"])
    }

    @Test("Late refresh success or definitive rejection cannot write or retire B", arguments: [false, true])
    func staleRefresh(_ rejects: Bool) async throws {
        let gate = CredentialRequestGate()
        let admissions = Mutex(0)
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path != "/auth/refresh" { return .init(status: 401) }
            await gate.pause()
            return rejects ? .init(status: 401, body: Data(#"{"error":"invalid","code":"INVALID_REFRESH_TOKEN"}"#.utf8)) : refreshed()
        }
        let (client, session) = makeClient(authority, admission: { _, _ in
            admissions.withLock { $0 += 1 }
            return .admitted(UUID())
        })
        defer { gate.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let old = Task { try await client.send(Ping()) }
        await gate.waitForEntries(1)
        let b = try install("B", in: authority)
        gate.open()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await old.value }
        #expect(try authority.snapshot() == b)
        #expect(admissions.withLock { $0 } == 0)
        #expect(!CredentialRequestURLProtocol.requests.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-B" })
    }

    @Test("Concurrent401s share one refresh; delayed old401 reuses the rotated revision")
    func coalescedAndDelayedUnauthorized() async throws {
        let refreshGate = CredentialRequestGate()
        let lateGate = CredentialRequestGate()
        let started = CredentialRequestGate()
        let oldRequests = Mutex(0)
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { await refreshGate.pause(); return refreshed() }
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" else { return success() }
            let index = oldRequests.withLock { count in count += 1; return count }
            if index == 3 { started.open() }
            if request.url?.path == "/late" { await lateGate.pause() }
            return .init(status: 401)
        }
        let (client, session) = makeClient(authority)
        defer { refreshGate.open(); lateGate.open(); started.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let first = Task { try await client.send(Ping()) }
        let second = Task { try await client.send(Ping()) }
        let delayed = Task { try await client.send(Ping(path: "/late")) }
        await refreshGate.waitForEntries(1)
        await started.pause()
        refreshGate.open()
        #expect(try await first.value.ok)
        #expect(try await second.value.ok)
        lateGate.open()
        #expect(try await delayed.value.ok)
        #expect(CredentialRequestURLProtocol.requests.filter { $0.url?.path == "/auth/refresh" }.count == 1)
        #expect(try authority.snapshot().tokenRevision == 1)
    }

    @Test("Canceled waiter does not cancel the shared refresh or another caller")
    func canceledWaiter() async throws {
        let refreshGate = CredentialRequestGate()
        let bothRequests = CredentialRequestGate()
        let count = Mutex(0)
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { await refreshGate.pause(); return refreshed() }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" {
                if count.withLock({ $0 += 1; return $0 }) == 2 { bothRequests.open() }
                return .init(status: 401)
            }
            return success()
        }
        let (client, session) = makeClient(authority)
        defer { refreshGate.open(); bothRequests.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let canceled = Task { try await client.send(Ping()) }
        await refreshGate.waitForEntries(1)
        let retained = Task { try await client.send(Ping()) }
        await bothRequests.pause()
        canceled.cancel()
        refreshGate.open()
        await #expect(throws: CancellationError.self) { try await canceled.value }
        #expect(try await retained.value.ok)
        #expect(CredentialRequestURLProtocol.requests.filter { $0.url?.path == "/auth/refresh" }.count == 1)
        #expect(try authority.snapshot().session.token == "fresh-A")
    }

    @Test("Ambiguous401, rate limit and server failure preserve committed credentials", arguments: [401, 429, 500, 503])
    func transientRefresh(_ status: Int) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let original = try install("A", in: authority)
        let admissions = Mutex(0)
        CredentialRequestURLProtocol.setHandler { request in
            request.url?.path == "/auth/refresh" ? .init(status: status) : .init(status: 401)
        }
        let (client, session) = makeClient(authority, admission: { _, _ in admissions.withLock { $0 += 1 }; return .admitted(UUID()) })
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        do { _ = try await client.send(Ping()); Issue.record("Refresh should fail") }
        catch {
            #expect(try authority.snapshot() == original)
            #expect(admissions.withLock { $0 } == 0)
        }
    }

    @Test("Definitive refresh codes admit only the captured rejection context", arguments: [
        CredentialRejectionCode.invalidRefreshToken, .refreshAccountUnavailable
    ])
    func definitiveRefresh(_ code: CredentialRejectionCode) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let original = try install("A", in: authority)
        let seen = Mutex<[CredentialRejectionContext]>([])
        CredentialRequestURLProtocol.setHandler { request in
            request.url?.path == "/auth/refresh"
                ? .init(status: 401, body: Data("{\"code\":\"\(code.rawValue)\",\"error\":\"rejected\"}".utf8))
                : .init(status: 401)
        }
        let (client, session) = makeClient(authority, admission: { received, context in
            #expect(received == code)
            seen.withLock { $0.append(context) }
            return .admitted(UUID())
        })
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.definitiveRejection(code, original.rejectionContext)) {
            try await client.send(Ping())
        }
        #expect(seen.withLock { $0 } == [original.rejectionContext])
        #expect(try authority.snapshot() == original) // transport never clears it
    }

    @Test("Wrong response owner is rejected without installing its tokens")
    func refreshOwnerMismatch() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let original = try install("A", in: authority)
        let seen = Mutex<[CredentialRejectionCode]>([])
        CredentialRequestURLProtocol.setHandler { request in request.url?.path == "/auth/refresh" ? refreshed("B") : .init(status: 401) }
        let (client, session) = makeClient(authority, admission: { code, _ in seen.withLock { $0.append(code) }; return .admitted(UUID()) })
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.definitiveRejection(.identityMismatch, original.rejectionContext)) { try await client.send(Ping()) }
        #expect(seen.withLock { $0 } == [.identityMismatch])
        #expect(try authority.snapshot() == original)
    }

    @Test("Opaque no-refresh sessions never post to refresh")
    func noRefreshCapability() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let original = try install("better-auth-owner", in: authority, refresh: false)
        CredentialRequestURLProtocol.setHandler { _ in .init(status: 401) }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.reauthenticationRequired) { try await client.send(Ping()) }
        #expect(CredentialRequestURLProtocol.requests.count == 1)
        #expect(try authority.snapshot() == original)
    }

    @Test("A failed refresh task is removed so an explicit later request can retry")
    func failedTaskCleanup() async throws {
        let count = Mutex(0)
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" {
                return count.withLock({ $0 += 1; return $0 }) == 1 ? .init(status: 503) : refreshed()
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" ? .init(status: 401) : success()
        }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        do { _ = try await client.send(Ping()); Issue.record("Expected initial failure") } catch {}
        #expect(try await client.send(Ping()).ok)
        #expect(count.withLock { $0 } == 2)
    }

    @Test("Refresh storage failure preserves old bytes and token revision")
    func refreshSaveFailure() async throws {
        let storage = CredentialRequestMemoryPersistence()
        let authority = SessionCredentialAuthority(persistence: storage)
        let original = try install("A", in: authority)
        let bytes = storage.bytes
        storage.failWrites = true
        CredentialRequestURLProtocol.setHandler { request in request.url?.path == "/auth/refresh" ? refreshed() : .init(status: 401) }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.unavailable(.securityStatus(-1))) { try await client.send(Ping()) }
        #expect(storage.bytes == bytes)
        #expect(try authority.snapshot() == original)
    }

    @Test("Consent suspension fences authenticated and anonymous requests before transport", arguments: [false, true])
    func consentFence(_ anonymous: Bool) async throws {
        let consent = CredentialRequestConsent()
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        if !anonymous { _ = try install("A", in: authority) }
        CredentialRequestURLProtocol.setHandler { _ in success() }
        let (client, session) = makeClient(authority, consent: consent)
        defer { consent.gate.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let old = Task { try await client.send(Ping(requiresDataUseConsent: true)) }
        await consent.gate.waitForEntries(1)
        let b = try install("B", in: authority)
        consent.gate.open()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await old.value }
        #expect(CredentialRequestURLProtocol.requests.isEmpty)
        #expect(try authority.snapshot() == b)
    }

    @Test("Anonymous transport retry cannot acquire a later signed-in owner")
    func anonymousRetry() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        CredentialRequestURLProtocol.setHandler { _ in
            _ = try install("B", in: authority)
            throw URLError(.networkConnectionLost)
        }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await client.send(Ping()) }
        #expect(CredentialRequestURLProtocol.requests.count == 1)
        #expect(CredentialRequestURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Successful normal A response is suppressed after B installs")
    func staleResponse() async throws {
        let gate = CredentialRequestGate()
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { _ in await gate.pause(); return success() }
        let (client, session) = makeClient(authority)
        defer { gate.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let old = Task { try await client.send(Ping()) }
        await gate.waitForEntries(1)
        _ = try install("B", in: authority)
        gate.open()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await old.value }
    }

    @Test("Admitted late create retains actual rotated A bearer; cleanup never refreshes B")
    func lateCreationReceipt() async throws {
        let created = CredentialRequestGate()
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let a = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { return refreshed() }
            if request.url?.path == "/cleanup" { return .init(status: 401) }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" { return .init(status: 401) }
            await created.pause()
            return success()
        }
        let (client, session) = makeClient(authority)
        defer { created.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let old = Task { try await client.sendAdmittedCreation(Ping(path: "/create")) }
        await created.waitForEntries(1)
        let b = try install("B", in: authority)
        created.open()
        let receipt = try await old.value
        #expect(receipt.response.ok)
        #expect(receipt.lease == a.lease)
        #expect(receipt.transmittedBearer == "fresh-A")
        let cleanup = WorkerClient(baseURL: URL(string: "https://credentials.example.invalid")!, session: session,
                                   admittedCleanupBearer: receipt.transmittedBearer,
                                   dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        await #expect(throws: CredentialAuthenticationFailure.reauthenticationRequired) { try await cleanup.send(Ping(path: "/cleanup")) }
        #expect(CredentialRequestURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-A")
        #expect(CredentialRequestURLProtocol.requests.filter { $0.url?.path == "/auth/refresh" }.count == 1)
        #expect(try authority.snapshot() == b)
    }

    @Test("Explicit adapter admission rejects deletion, stale and legacy scopes before transport", arguments: ["deletion", "stale", "legacy"])
    func explicitAdapterScopeRejection(_ kind: String) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let a = try install("A", in: authority)
        var context = CredentialRequestContext.normal(a.lease)
        if kind == "deletion" {
            let transition = try authority.beginTransition(expected: authority.attemptTicket())
            guard case .loaded(let outgoing) = transition.outgoing else { Issue.record("Missing outgoing"); return }
            context = .deletion(transactionID: transition.id, outgoingLease: outgoing.lease)
        } else if kind == "stale" {
            _ = try install("B", in: authority)
        }
        CredentialRequestURLProtocol.setHandler { _ in success() }
        let (scoped, session) = makeClient(authority)
        let client = kind == "legacy"
            ? WorkerClient(baseURL: URL(string: "https://credentials.example.invalid")!, session: session,
                           tokenProvider: StaticTokenProvider("legacy")) : scoped
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try await client.sendAdmittedCreation(Ping(), credentialContext: context)
        }
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try await client.refreshAuthentication(credentialContext: context, failed: a.rejectionContext)
        }
        #expect(CredentialRequestURLProtocol.requests.isEmpty)
        if kind != "deletion" {
            #expect(try authority.snapshot().session.token == (kind == "stale" ? "access-B" : "access-A"))
        }
    }

    @Test("Explicit refresh refuses inconsistent failed lease, ticket or future revision", arguments: ["lease", "ticket", "revision"])
    func explicitRefreshTupleRejection(_ kind: String) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let a = try install("A", in: authority)
        let other = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let b = try install("B", in: other)
        let failed = CredentialRejectionContext(
            lease: kind == "lease" ? b.lease : a.lease,
            tokenRevision: kind == "revision" ? a.tokenRevision + 1 : a.tokenRevision,
            ticket: kind == "ticket" ? b.ticket : a.ticket
        )
        CredentialRequestURLProtocol.setHandler { _ in refreshed() }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try await client.refreshAuthentication(credentialContext: .normal(a.lease), failed: failed)
        }
        #expect(CredentialRequestURLProtocol.requests.isEmpty)
        #expect(try authority.snapshot() == a)
    }

    @Test("Explicit refresh rotates once and reuses a delayed rejected revision")
    func explicitRefreshSameLeaseRevision() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let a = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            #expect(request.url?.path == "/auth/refresh")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return refreshed()
        }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let rotated = try await client.refreshAuthentication(credentialContext: .normal(a.lease), failed: a.rejectionContext)
        let reused = try await client.refreshAuthentication(credentialContext: .normal(a.lease), failed: a.rejectionContext)
        #expect(rotated == reused)
        #expect(rotated.lease == a.lease)
        #expect(rotated.tokenRevision == a.tokenRevision + 1)
        #expect(rotated.session.token == "fresh-A")
        #expect(CredentialRequestURLProtocol.requests.count == 1)
        #expect(try authority.snapshot() == rotated)
    }

    @Test("Explicit refresh cannot commit or retire after B replaces A", arguments: [false, true])
    func explicitRefreshSuspendedOwner(_ rejects: Bool) async throws {
        let gate = CredentialRequestGate()
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let a = try install("A", in: authority)
        let admissions = Mutex(0)
        CredentialRequestURLProtocol.setHandler { request in
            #expect(request.url?.path == "/auth/refresh")
            await gate.pause()
            return rejects
                ? .init(status: 401, body: Data(#"{"code":"INVALID_REFRESH_TOKEN"}"#.utf8)) : refreshed()
        }
        let (client, session) = makeClient(authority, admission: { _, _ in
            admissions.withLock { $0 += 1 }
            return .admitted(UUID())
        })
        let old = Task { try await client.refreshAuthentication(credentialContext: .normal(a.lease), failed: a.rejectionContext) }
        defer { old.cancel(); gate.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await gate.waitForEntries(1)
        let b = try install("B", in: authority)
        gate.open()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await old.value }
        #expect(try authority.snapshot() == b)
        #expect(admissions.withLock { $0 } == 0)
        #expect(CredentialRequestURLProtocol.requests.count == 1)
    }

    @Test("Explicit create retains original admission and actual bearer after late success", arguments: [false, true])
    func explicitCreationReceipt(_ rotates: Bool) async throws {
        let created = CredentialRequestGate()
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let a = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { return refreshed() }
            if request.url?.path == "/cleanup" { return success() }
            if rotates, request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" { return .init(status: 401) }
            await created.pause()
            return success()
        }
        let (client, session) = makeClient(authority)
        let old = Task { try await client.sendAdmittedCreation(Ping(path: "/create"), credentialContext: .normal(a.lease)) }
        defer { old.cancel(); created.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await created.waitForEntries(1)
        let b = try install("B", in: authority)
        created.open()
        let receipt = try await old.value
        #expect(receipt.response.ok)
        #expect(receipt.lease == a.lease)
        #expect(receipt.transmittedBearer == (rotates ? "fresh-A" : "access-A"))
        let cleanup = WorkerClient(baseURL: URL(string: "https://credentials.example.invalid")!, session: session,
                                   admittedCleanupBearer: receipt.transmittedBearer,
                                   dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
        #expect(try await cleanup.send(Ping(path: "/cleanup")).ok)
        #expect(CredentialRequestURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
                == (rotates ? ["Bearer access-A", nil, "Bearer fresh-A", "Bearer fresh-A"]
                            : ["Bearer access-A", "Bearer access-A"]))
        #expect(try authority.snapshot() == b)
    }

    @Test("Outgoing DELETE is transaction-bound and cannot refresh or adopt B", arguments: [false, true])
    func deletionContext(_ rejects: Bool) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        let transition = try authority.beginTransition(expected: authority.attemptTicket())
        guard case .loaded(let outgoing) = transition.outgoing else { Issue.record("Missing outgoing context"); return }
        let context = CredentialRequestContext.deletion(transactionID: transition.id, outgoingLease: outgoing.lease)
        CredentialRequestURLProtocol.setHandler { _ in rejects ? .init(status: 401) : success() }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        if rejects {
            await #expect(throws: CredentialAuthenticationFailure.reauthenticationRequired) {
                try await client.send(Ping(method: .DELETE), credentialContext: context)
            }
        } else { #expect(try await client.send(Ping(method: .DELETE), credentialContext: context).ok) }
        _ = try install("B", in: authority)
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await client.send(Ping(method: .DELETE), credentialContext: context) }
        #expect(CredentialRequestURLProtocol.requests.count == 1)
        #expect(CredentialRequestURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-A")
    }

    @Test("A repeated401 after one refresh has a typed terminal result on every transport", arguments: ["send", "binary", "stream"])
    func repeatedUnauthorized(_ transport: String) async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        let original = try install("A", in: authority)
        let admissions = Mutex(0)
        CredentialRequestURLProtocol.setHandler { request in
            request.url?.path == "/auth/refresh" ? refreshed() : .init(status: 401)
        }
        let (client, session) = makeClient(authority, admission: { _, _ in
            admissions.withLock { $0 += 1 }
            return .admitted(UUID())
        })
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        await #expect(throws: CredentialAuthenticationFailure.reauthenticationRequired) {
            switch transport {
            case "send": _ = try await client.send(Ping())
            case "binary": _ = try await client.downloadData(Audio())
            default: for try await _ in await client.stream(Audio()) {}
            }
        }
        let current = try authority.snapshot()
        #expect(current.lease == original.lease)
        #expect(current.tokenRevision == 1)
        #expect(current.session.token == "fresh-A")
        #expect(current.refreshToken == "fresh-refresh-A")
        #expect(admissions.withLock { $0 } == 0)
        #expect(CredentialRequestURLProtocol.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
                == ["Bearer access-A", nil, "Bearer fresh-A"])
    }

    @Test("Binary401 retry remains on the same owner and validates complete audio")
    func binaryRefresh() async throws {
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { request in
            if request.url?.path == "/auth/refresh" { return refreshed() }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" { return .init(status: 401) }
            return .init(status: 200, body: Data("mp3".utf8), headers: ["Content-Type": "audio/mpeg", "Content-Length": "3"])
        }
        let (client, session) = makeClient(authority)
        defer { session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        #expect(try await client.downloadData(Audio()) == Data("mp3".utf8))
        #expect(CredentialRequestURLProtocol.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-A")
    }

    @Test("Stream fencing suppresses every chunk after the original owner changes")
    func streamFence() async throws {
        let bodyGate = CredentialRequestGate()
        let received = CredentialRequestGate()
        let chunks = Mutex<[Data]>([])
        let authority = SessionCredentialAuthority(persistence: CredentialRequestMemoryPersistence())
        _ = try install("A", in: authority)
        CredentialRequestURLProtocol.setHandler { _ in
            .init(status: 200, chunks: [Data(repeating: 65, count: 4096), Data("late".utf8)], betweenChunks: bodyGate)
        }
        let (client, session) = makeClient(authority)
        defer { bodyGate.open(); received.open(); session.invalidateAndCancel(); CredentialRequestURLProtocol.reset() }
        let stream = await client.stream(Audio())
        let consumer = Task {
            for try await data in stream { chunks.withLock { $0.append(data) }; received.open() }
        }
        await received.pause()
        _ = try install("B", in: authority)
        bodyGate.open()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await consumer.value }
        #expect(chunks.withLock { $0.count } == 1)
        #expect(CredentialRequestURLProtocol.requests.count == 1)
    }
}

private final class CredentialRequestMemoryPersistence: SessionCredentialPersistence, Sendable {
    private struct State { var bytes: Data?; var reads = 0; var failWrites = false }
    private let state = Mutex(State())
    var bytes: Data? { state.withLock { $0.bytes } }
    var readCount: Int { state.withLock { $0.reads } }
    var failWrites: Bool {
        get { state.withLock { $0.failWrites } }
        set { state.withLock { $0.failWrites = newValue } }
    }
    func readCanonical() -> Data? { state.withLock { $0.reads += 1; return $0.bytes } }
    func writeCanonical(_ data: Data) throws {
        try state.withLock { state in
            if state.failWrites { throw CredentialStorageFailure.securityStatus(-1) }
            state.bytes = data
        }
    }
    func readLegacy() -> LegacyCredentials { .init(accessToken: nil, refreshToken: nil, userID: nil) }
    func removeLegacy() {}
}

/// Cancellation resumes only this waiter; test teardown opens every fixture gate.
private final class CredentialRequestGate: Sendable {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Never> }
    private struct Observer { let count: Int; let waiter: Waiter }
    private struct State { var open = false; var entries = 0; var paused: [Waiter] = []; var observers: [Observer] = [] }
    private let state = Mutex(State())

    func pause() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock { state in
                    state.entries += 1
                    let ready = state.observers.filter { $0.count <= state.entries }
                    state.observers.removeAll { $0.count <= state.entries }
                    ready.forEach { $0.waiter.continuation.resume() }
                    if state.open || Task.isCancelled { continuation.resume() }
                    else { state.paused.append(Waiter(id: id, continuation: continuation)) }
                }
            }
        } onCancel: { self.cancel(id) }
    }
    func waitForEntries(_ count: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.withLock { state in
                    if state.entries >= count || Task.isCancelled { continuation.resume() }
                    else { state.observers.append(Observer(count: count, waiter: Waiter(id: id, continuation: continuation))) }
                }
            }
        } onCancel: { self.cancel(id) }
    }
    func open() {
        state.withLock { state in
            state.open = true
            state.paused.forEach { $0.continuation.resume() }
            state.paused.removeAll()
            state.observers.forEach { $0.waiter.continuation.resume() }
            state.observers.removeAll()
        }
    }
    private func cancel(_ id: UUID) {
        state.withLock { state in
            if let index = state.paused.firstIndex(where: { $0.id == id }) { state.paused.remove(at: index).continuation.resume() }
            if let index = state.observers.firstIndex(where: { $0.waiter.id == id }) { state.observers.remove(at: index).waiter.continuation.resume() }
        }
    }
}

private struct CredentialRequestConsent: WorkerDataUseConsentProvider {
    let gate = CredentialRequestGate()
    func hasCurrentDataUseConsent() async -> Bool { await gate.pause(); return true }
}

/// Separate serialized suite storage; no shared production/test URLProtocol routing.
private final class CredentialRequestURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        let chunks: [Data]
        let headers: [String: String]
        let betweenChunks: CredentialRequestGate?
        init(status: Int, body: Data = Data(), headers: [String: String] = ["Content-Type": "application/json"]) {
            self.init(status: status, chunks: [body], headers: headers, betweenChunks: nil)
        }
        init(status: Int, chunks: [Data], headers: [String: String] = ["Content-Type": "application/json"], betweenChunks: CredentialRequestGate?) {
            self.status = status; self.chunks = chunks; self.headers = headers; self.betweenChunks = betweenChunks
        }
    }
    private struct State {
        var handler: (@Sendable (URLRequest) async throws -> Response)?
        var requests: [URLRequest] = []
    }
    private static let state = Mutex(State())
    private let loadingTask = Mutex<Task<Void, Never>?>(nil)
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async throws -> Response) {
        state.withLock { $0 = State(handler: handler) }
    }
    static func reset() { state.withLock { $0 = State() } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let handler = Self.state.withLock { state in state.requests.append(request); return state.handler }
        let worker = Task { @Sendable [self, request, handler] in
            do {
                guard let handler else { throw URLError(.badServerResponse) }
                let result = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                for (index, chunk) in result.chunks.enumerated() {
                    if index > 0 { await result.betweenChunks?.pause() }
                    try Task.checkCancellation()
                    client?.urlProtocol(self, didLoad: chunk)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                if !Task.isCancelled { client?.urlProtocol(self, didFailWithError: error) }
            }
        }
        loadingTask.withLock { $0 = worker }
    }
    override func stopLoading() { loadingTask.withLock { $0?.cancel(); $0 = nil } }
}
