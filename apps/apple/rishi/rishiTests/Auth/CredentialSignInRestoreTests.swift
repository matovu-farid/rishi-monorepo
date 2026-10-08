import Foundation
import Synchronization
import Testing
@testable import rishi

@MainActor
@Suite("Canonical sign-in and restore — isolated actual owners", .serialized, .timeLimit(.minutes(1)))
struct CredentialSignInRestoreTests {
    private func user(_ rawID: String, email: String? = nil) -> User {
        User(id: DerivedUserID.from(rawID), email: email, name: "Fixture")
    }

    @Test("Canonical installation preserves opaque IDs, optional refresh and private-relay metadata", arguments: [false, true])
    func sessionMetadata(_ opaque: Bool) async throws {
        let fixture = try AuthenticationFixture()
        defer { fixture.close() }
        let rawID = opaque ? "better-auth|opaque-fixture" : UUID().uuidString
        let email = "fixture@privaterelay.appleid.com"
        let user = user(rawID, email: email)
        let box = CurrentUserBox()
        let attempt = fixture.adapter.beginAttempt()
        try await fixture.adapter.completeSignIn(
            session: Session(token: "fixture-access", userId: rawID, email: email),
            refreshToken: opaque ? nil : "fixture-refresh", user: user,
            attempt: attempt, debugOnboarding: true
        ) { box.signIn(user: user) }
        let installed = try fixture.authority.snapshot()
        #expect(installed.session.userId == rawID)
        #expect(installed.session.email == email)
        #expect(installed.refreshToken == (opaque ? nil : "fixture-refresh"))
        #expect(fixture.resources.dependencies.cachedUserId == user.id)
        #expect(await fixture.consent.record(for: installed.lease) != nil)
        #expect(fixture.effects.snapshot() == [installed.lease, installed.lease, installed.lease])
        guard case .signedIn(let actual) = box.state else { Issue.record("Installation did not publish"); return }
        #expect(actual == user)
    }

    @Test("Ticket captured before a provider exchange rejects its late result")
    func staleExchange() async throws {
        let fixture = try AuthenticationFixture()
        defer { fixture.close() }
        let a = fixture.adapter.beginAttempt()
        let bUser = user("B")
        let box = CurrentUserBox()
        try await fixture.signIn("B", user: bUser, into: box)
        let b = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try await fixture.adapter.completeSignIn(session: Session(token: "late-A", userId: "A", email: nil),
                refreshToken: nil, user: user("A"), attempt: a, debugOnboarding: false) { box.signIn(user: user("A")) }
        }
        #expect(try fixture.authority.snapshot() == b)
        #expect(fixture.storage.bytes == bytes)
        #expect(!fixture.adapter.mayReportFailure(for: a))
        guard case .signedIn(let actual) = box.state else { Issue.record("B presentation changed"); return }
        #expect(actual == bUser)
    }

    @Test("Actual anonymous exchange needs no lease, sends no old bearer, and suppresses a late result", arguments: [false, true])
    func anonymousExchange(_ hasExistingSession: Bool) async throws {
        let fixture = try AuthenticationFixture(installedRawID: hasExistingSession ? "A" : nil)
        defer { fixture.close() }
        let gate = CredentialStagingGate()
        AuthenticationURLProtocol.setHandler { _ in
            await gate.suspend()
            return .init(200, #"{"token":"access-A","user":{"id":"A","email":null,"name":"A"}}"#)
        }
        let attempt = fixture.adapter.beginAttempt()
        let exchange = Task {
            try await fixture.adapter.exchange(EmailPasswordSignInEndpoint(email: "fixture@example.invalid", password: "fixture-only"),
                                               attempt: attempt)
        }
        defer { exchange.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        let sent = try #require(AuthenticationURLProtocol.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!sent.httpShouldHandleCookies)
        let box = CurrentUserBox()
        let bUser = user("B")
        try await fixture.signIn("B", user: bUser, into: box)
        let b = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        await gate.resume()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await exchange.value }
        #expect(AuthenticationURLProtocol.requests.count == 1)
        #expect(try fixture.authority.snapshot() == b)
        #expect(fixture.storage.bytes == bytes)
        guard case .signedIn(let actual) = box.state else { Issue.record("Late exchange changed B presentation"); return }
        #expect(actual == bUser)
    }

    @Test("Canonical helper refuses competing owners even when installed leases match", arguments: ["worker", "dependencies"])
    func mismatchedOwner(_ owner: String) throws {
        let fixture = try AuthenticationFixture(installedRawID: "A", rehydrateInitialAuthority: true)
        defer { fixture.close() }
        let other = SessionCredentialAuthority(persistence: fixture.storage)
        #expect(try other.snapshot().lease == fixture.authority.snapshot().lease)
        let worker = WorkerClient(baseURL: URL(string: "https://authentication.example.invalid")!, session: fixture.session,
            credentialAuthority: owner == "worker" ? other : fixture.authority,
            dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
            admitCredentialRejection: { _, _ in .stale })
        let dependencies = owner == "dependencies"
            ? AppDependencies(credentialAuthority: other, userIdBox: UserIdBox(nil), accountGeneration: 17,
                persistAccountGeneration: { _ in Issue.record("Misbound helper changed generation") },
                credentialCleanup: { _ in Issue.record("Misbound helper began cleanup") })
            : fixture.resources.dependencies
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try CredentialAuthenticationAdapter(authority: fixture.authority, dependencies: dependencies,
                worker: worker, consent: fixture.consent,
                installSession: { session, refresh, tx in try await fixture.resources.dependencies.installCredentialSession(session, refreshToken: refresh, in: tx) },
                restoreIdentity: { try await fixture.resources.dependencies.restoreCredentialIdentity($0) },
                registerPendingDeviceToken: { _ in Issue.record("Misbound helper registered device") },
                completeDebugOnboarding: { _ in Issue.record("Misbound helper completed onboarding") },
                refreshEntitlement: { _ in Issue.record("Misbound helper refreshed entitlement") })
        }
        #expect(AuthenticationURLProtocol.requests.isEmpty)
    }

    @Test("Canonical intent rejects competing dependencies or Worker before effects", arguments: ["worker", "dependencies"])
    func mismatchedIntentOwner(_ owner: String) async throws {
        let fixture = try AuthenticationFixture(installedRawID: "A", rehydrateInitialAuthority: true)
        defer { fixture.close() }
        let original = try fixture.authority.snapshot()
        let other = SessionCredentialAuthority(persistence: fixture.storage)
        let copied = try other.snapshot()
        #expect(copied.lease == original.lease)
        #expect(copied.session == original.session)
        #expect(copied.refreshToken == original.refreshToken)
        #expect(copied.ticket != original.ticket)
        let bytes = fixture.storage.bytes
        if owner == "worker" {
            let worker = WorkerClient(baseURL: URL(string: "https://authentication.example.invalid")!, session: fixture.session,
                credentialAuthority: other, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
                admitCredentialRejection: { _, _ in Issue.record("Misbound intent admitted rejection"); return .stale })
            await #expect(throws: RishiAppIntentRuntimeError.accountChanged) {
                try await RishiAppIntentRuntime.validateServerIdentity(using: worker, snapshot: original,
                    authority: fixture.authority, admitCredentialRejection: { _, _ in
                        Issue.record("Misbound intent admitted rejection"); return .stale
                    })
            }
        } else {
            let dependencies = AppDependencies(credentialAuthority: other, userIdBox: UserIdBox(nil), accountGeneration: 17,
                persistAccountGeneration: { _ in Issue.record("Misbound intent changed generation") },
                credentialCleanup: { _ in Issue.record("Misbound intent began cleanup") })
            await #expect(throws: RishiAppIntentRuntimeError.accountChanged) {
                try await RishiAppIntentRuntime.snapshot(dependencies: dependencies, authority: fixture.authority,
                    restoreIdentity: { _ in Issue.record("Misbound intent restored identity") })
            }
        }
        #expect(AuthenticationURLProtocol.requests.isEmpty)
        #expect(fixture.storage.bytes == bytes)
        #expect(try fixture.authority.snapshot() == original)
    }

    @Test("Canonical recovery refuses legacy or misbound Shared clients before transport", arguments: ["legacy", "authority", "lease", "valid"])
    func sharedClientBinding(_ mode: String) throws {
        let fixture = try AuthenticationFixture(installedRawID: "A", rehydrateInitialAuthority: true)
        defer { fixture.close() }
        let original = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        let url = URL(string: "https://authentication.example.invalid")!
        let api: SharedReadingAPI
        if mode == "legacy" {
            api = SharedReadingAPI(baseURL: url, session: fixture.session, tokenProvider: StaticTokenProvider("fixture-only"))
        } else {
            let authority = mode == "authority" ? SessionCredentialAuthority(persistence: fixture.storage) : fixture.authority
            if mode == "authority" { #expect(try authority.snapshot().lease == original.lease) }
            let lease: CredentialLease
            if mode == "lease" {
                let other = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
                lease = try installStagingCredentials("B", authority: other).lease
            } else { lease = original.lease }
            let worker = WorkerClient(baseURL: url, session: fixture.session, credentialAuthority: authority,
                dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(), admitCredentialRejection: { _, _ in .stale })
            api = try SharedReadingAPI(baseURL: url, session: fixture.session, credentialAuthority: authority,
                workerClient: worker, credentialContext: .normal(lease))
        }
        let storage = BookFileStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            bookStore: InMemoryBookStore(), coverExtractors: [:])
        let books = SessionBookService(fileStorage: storage, userIdProvider: { DerivedUserID.from("A") }, session: fixture.session)
        let construct = {
            try ActiveReadingSessionsView(api: api, bookService: books, userId: DerivedUserID.from("A"),
                sessionRegistry: SharedReadingSessionRegistry(), router: AppRouter(sharedReaderAccountIDProvider: { fixture.resources.dependencies.cachedUserId }),
                credentialSnapshot: original, credentialAuthority: fixture.authority,
                accountIdentity: LibraryAccountIdentity(userID: DerivedUserID.from("A"), generation: 0),
                currentAccountIdentity: { LibraryAccountIdentity(userID: DerivedUserID.from("A"), generation: 0) })
        }
        if mode == "valid" { _ = try construct() }
        else { #expect(throws: CredentialAuthenticationFailure.accountChanged) { try construct() } }
        #expect(AuthenticationURLProtocol.requests.isEmpty)
        #expect(fixture.storage.bytes == bytes)
        #expect(try fixture.authority.snapshot() == original)
    }

    @Test("Superseded installation cannot publish, roll back, or mutate B after an admitted await", arguments: ["install", "consent", "device", "entitlement"])
    func supersededEffects(_ phase: String) async throws {
        let gate = CredentialStagingGate()
        let fixture = try AuthenticationFixture(phase: phase, gate: gate)
        defer { fixture.close() }
        let box = CurrentUserBox()
        let a = Task { try await fixture.signIn("A", user: user("A"), into: box) }
        defer { a.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        let bUser = user("B")
        try await fixture.signIn("B", user: bUser, into: box)
        let b = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        let generation = fixture.resources.dependencies.accountGeneration
        let record = await fixture.consent.record(for: b.lease)
        let effects = fixture.effects.snapshot()
        await gate.resume()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await a.value }
        #expect(try fixture.authority.snapshot() == b)
        #expect(fixture.storage.bytes == bytes)
        #expect(fixture.resources.dependencies.accountGeneration == generation)
        #expect(fixture.resources.dependencies.cachedUserId == bUser.id)
        #expect(fixture.resources.dependencies.pendingAccountChange == nil)
        let currentRecord = await fixture.consent.record(for: b.lease)
        #expect(currentRecord?.version == record?.version)
        #expect(currentRecord?.timestamp == record?.timestamp)
        #expect(fixture.effects.snapshot() == effects)
        guard case .signedIn(let actual) = box.state else { Issue.record("B presentation changed"); return }
        #expect(actual == bUser)
    }

    @Test("A failed owned install retires only its original transaction; durable failure stays fenced")
    func ownedRollback() async throws {
        let fixture = try AuthenticationFixture()
        defer { fixture.close() }
        fixture.storage.failsWrites = true
        let attempt = fixture.adapter.beginAttempt()
        await #expect(throws: CredentialAuthenticationFailure.unavailable(.securityStatus(-50))) {
            try await fixture.adapter.completeSignIn(session: Session(token: "A", userId: "A", email: nil),
                refreshToken: nil, user: user("A"), attempt: attempt, debugOnboarding: false) {
                Issue.record("Failed durable installation published")
            }
        }
        let tx = try #require(fixture.resources.dependencies.pendingAccountChange)
        let retirement = try #require(fixture.resources.dependencies.retireCredentialAccount(tx))
        await retirement.value
        #expect(fixture.adapter.mayReportFailure(for: attempt))
        #expect(fixture.resources.dependencies.pendingAccountChange === tx)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) { try fixture.authority.snapshot() }
        #expect(fixture.resources.dependencies.credentialRetirementResult != nil)
        fixture.storage.failsWrites = false
        let retry = try #require(fixture.resources.dependencies.retryCredentialRetirement())
        await retry.value
        #expect(fixture.resources.dependencies.pendingAccountChange == nil)
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try fixture.authority.snapshot() }
    }

    @Test("Temporary cold restore retains credentials and retries the same installed lease")
    func temporaryRestoreAndRetry() async throws {
        let fixture = try AuthenticationFixture(installedRawID: "A")
        defer { fixture.close() }
        let original = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        AuthenticationURLProtocol.setHandler { _ in .init(503, #"{"error":"temporary","code":"SERVICE_UNAVAILABLE"}"#) }
        let box = CurrentUserBox()
        await fixture.adapter.restore(into: box)
        guard case .authenticationRecovery(let recovery) = box.state else { Issue.record("Failure became signed out"); return }
        #expect(recovery.kind == .temporarilyUnavailable)
        #expect(fixture.storage.bytes == bytes)
        #expect(try fixture.authority.snapshot() == original)
        let expected = user("A")
        AuthenticationURLProtocol.setHandler { _ in .init(200, try JSONEncoder().encode(expected)) }
        await fixture.adapter.restore(into: box)
        guard case .signedIn(let restored) = box.state else { Issue.record("Retry did not publish"); return }
        #expect(restored == expected)
        #expect(try fixture.authority.snapshot() == original)
        #expect(fixture.storage.bytes == bytes)
    }

    @Test("Temporary failure keeps a valid same-account signed-in presentation")
    func retainValidPresentation() async throws {
        let fixture = try AuthenticationFixture(installedRawID: "A")
        defer { fixture.close() }
        let box = CurrentUserBox()
        let expected = user("A")
        box.signIn(user: expected)
        AuthenticationURLProtocol.setHandler { _ in .init(503, #"{"error":"temporary","code":"SERVICE_UNAVAILABLE"}"#) }
        await fixture.adapter.restore(into: box)
        guard case .signedIn(let actual) = box.state else { Issue.record("Temporary failure removed valid presentation"); return }
        #expect(actual == expected)
        #expect(fixture.resources.dependencies.credentialRetirementResult == nil)
    }

    @Test("A late restore response cannot change B across success, unavailable or unauthorized", arguments: [200, 503, 401])
    func staleRestore(_ status: Int) async throws {
        let gate = CredentialStagingGate()
        let fixture = try AuthenticationFixture(installedRawID: "A")
        defer { fixture.close() }
        let responseUser = user("A")
        AuthenticationURLProtocol.setHandler { _ in
            await gate.suspend()
            return .init(status, try JSONEncoder().encode(responseUser))
        }
        let box = CurrentUserBox()
        let old = Task { await fixture.adapter.restore(into: box) }
        defer { old.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        let bUser = user("B")
        try await fixture.signIn("B", user: bUser, into: box)
        let b = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        let consent = await fixture.consent.record(for: b.lease)
        await gate.resume(); await old.value
        #expect(try fixture.authority.snapshot() == b)
        #expect(fixture.storage.bytes == bytes)
        #expect(fixture.resources.dependencies.cachedUserId == bUser.id)
        let currentConsent = await fixture.consent.record(for: b.lease)
        #expect(currentConsent?.version == consent?.version)
        #expect(currentConsent?.timestamp == consent?.timestamp)
        #expect(AuthenticationURLProtocol.requests.count == 1)
        guard case .signedIn(let actual) = box.state else { Issue.record("Late restore changed B presentation"); return }
        #expect(actual == bUser)
    }

    @Test("Definitive retirement projects its exact owner and retries a failed tombstone without joining the request", arguments: [false, true])
    func definitiveRetirement(_ failClear: Bool) async throws {
        let gate = CredentialStagingGate()
        defer { Task { await gate.resume() } }
        let fixture = try AuthenticationFixture(installedRawID: "A", cleanupGate: gate)
        defer { fixture.close() }
        let original = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        AuthenticationURLProtocol.setHandler { request in
            request.url?.path == "/auth/refresh"
                ? .init(401, #"{"error":"rejected","code":"INVALID_REFRESH_TOKEN"}"#) : .init(401)
        }
        let box = CurrentUserBox()
        await fixture.adapter.restore(into: box)
        await gate.waitUntilEntered()
        guard case .authenticationRecovery(let pending) = box.state else { Issue.record("Definitive admission did not project"); return }
        #expect(pending.kind == .signInRequired)
        let tx = try #require(fixture.resources.dependencies.pendingAccountChange)
        let owner = try #require(fixture.resources.dependencies.retireCredentialAccount(tx))
        fixture.storage.failsWrites = failClear
        await gate.resume(); await owner.value
        fixture.adapter.reconcileRetirement(into: box)
        if failClear {
            guard case .authenticationRecovery(let failed) = box.state else { Issue.record("Failed clear disappeared"); return }
            #expect(failed.kind == .cleanupIncomplete)
            #expect(fixture.storage.bytes == bytes)
            fixture.storage.failsWrites = false
            await fixture.adapter.restore(into: box)
            let retry = try #require(fixture.resources.dependencies.retireCredentialAccount(tx))
            await retry.value
            fixture.adapter.reconcileRetirement(into: box)
        }
        guard case .signedOut = box.state else { Issue.record("Admitted clear did not project signed out"); return }
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try fixture.authority.snapshot() }
        #expect(AuthenticationURLProtocol.requests.count == 2)
        #expect(fixture.resources.dependencies.credentialRetirementProjection(for: original.rejectionContext) != nil)
    }

    @Test("Opaque bare401 requests sign-in recovery without deleting a real canonical record")
    func ambiguousRestore() async throws {
        let fixture = try AuthenticationFixture(installedRawID: "A", refreshToken: nil)
        defer { fixture.close() }
        let original = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        AuthenticationURLProtocol.setHandler { _ in .init(401) }
        let box = CurrentUserBox(); box.signIn(user: user("A"))
        await fixture.adapter.restore(into: box)
        guard case .authenticationRecovery(let recovery) = box.state else { Issue.record("Reauthentication did not request recovery"); return }
        #expect(recovery.kind == .signInRequired)
        #expect(try fixture.authority.snapshot() == original)
        #expect(fixture.storage.bytes == bytes)
        #expect(fixture.resources.dependencies.pendingAccountChange == nil)
        #expect(AuthenticationURLProtocol.requests.count == 1)
    }

    @Test("Explicit sign-out projects its original retirement and retries failed durable clear", arguments: [false, true])
    func explicitSignOut(_ failClear: Bool) async throws {
        let gate = CredentialStagingGate()
        defer { Task { await gate.resume() } }
        let fixture = try AuthenticationFixture(installedRawID: "A", cleanupGate: gate)
        defer { fixture.close() }
        let original = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        let box = CurrentUserBox(); box.signIn(user: user("A"))
        try fixture.adapter.retireCurrentAccount(expected: original.ticket, into: box)
        await gate.waitUntilEntered()
        guard case .authenticationRecovery(let pending) = box.state else { Issue.record("Explicit retirement was not projected"); return }
        #expect(pending.kind == .signInRequired)
        let tx = try #require(fixture.resources.dependencies.pendingAccountChange)
        let task = try #require(fixture.resources.dependencies.retireCredentialAccount(tx))
        defer { task.cancel(); Task { await gate.resume() } }
        fixture.storage.failsWrites = failClear
        await gate.resume(); await task.value
        fixture.adapter.reconcileRetirement(into: box)
        if failClear {
            guard case .authenticationRecovery(let failed) = box.state else { Issue.record("Explicit failed clear disappeared"); return }
            #expect(failed.kind == .cleanupIncomplete)
            #expect(fixture.storage.bytes == bytes)
            #expect(fixture.resources.dependencies.pendingAccountChange === tx)
            fixture.storage.failsWrites = false
            await fixture.adapter.restore(into: box)
            await (try #require(fixture.resources.dependencies.retireCredentialAccount(tx))).value
            fixture.adapter.reconcileRetirement(into: box)
        }
        guard case .signedOut = box.state else { Issue.record("Explicit durable clear did not sign out"); return }
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try fixture.authority.snapshot() }
        #expect(fixture.resources.dependencies.pendingAccountChange == nil)
        #expect(AuthenticationURLProtocol.requests.isEmpty)
    }

    @Test("Late explicit A completion or button cannot project or retire a subsequently installed B")
    func supersededExplicitCompletion() async throws {
        let fixture = try AuthenticationFixture(installedRawID: "A")
        defer { fixture.close() }
        let a = try fixture.authority.snapshot()
        let box = CurrentUserBox(); box.signIn(user: user("A"))
        try fixture.adapter.retireCurrentAccount(expected: a.ticket, into: box)
        let outgoing = try #require(fixture.resources.dependencies.pendingAccountChange)
        await (try #require(fixture.resources.dependencies.retireCredentialAccount(outgoing))).value
        let tx = try fixture.resources.dependencies.beginAccountChange(expectedCredentialTicket: fixture.authority.attemptTicket())
        let b = try await fixture.resources.dependencies.installCredentialSession(
            Session(token: "access-B", userId: "B", email: nil), refreshToken: nil, in: tx)
        let bUser = user("B")
        #expect(fixture.resources.dependencies.performCredentialMutation(b.lease) { box.signIn(user: bUser) })
        let bytes = fixture.storage.bytes
        let generation = fixture.resources.dependencies.accountGeneration
        fixture.adapter.reconcileRetirement(into: box)
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try fixture.adapter.retireCurrentAccount(expected: a.ticket, into: box)
        }
        #expect(try fixture.authority.snapshot() == b)
        #expect(fixture.storage.bytes == bytes)
        #expect(fixture.resources.dependencies.cachedUserId == bUser.id)
        #expect(fixture.resources.dependencies.accountGeneration == generation)
        #expect(fixture.resources.dependencies.pendingAccountChange == nil)
        guard case .signedIn(let actual) = box.state else { Issue.record("A completion changed B presentation"); return }
        #expect(actual == bUser)
        #expect(AuthenticationURLProtocol.requests.isEmpty)
    }

    @Test("Canceled current restore releases loading and retains its canonical record")
    func canceledRestore() async throws {
        let gate = CredentialStagingGate()
        let fixture = try AuthenticationFixture(installedRawID: "A")
        defer { fixture.close() }
        let original = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        AuthenticationURLProtocol.setHandler { _ in
            await gate.suspend()
            try Task.checkCancellation()
            return .init(200)
        }
        let box = CurrentUserBox()
        let task = Task { await fixture.adapter.restore(into: box) }
        defer { task.cancel(); Task { await gate.resume() } }
        await gate.waitUntilEntered()
        task.cancel(); await task.value
        guard case .signedOut = box.state else { Issue.record("Cancellation stranded loading"); return }
        #expect(try fixture.authority.snapshot() == original)
        #expect(fixture.storage.bytes == bytes)
        #expect(fixture.resources.dependencies.pendingAccountChange == nil)
    }

    @Test("Canonical intent reader distinguishes inaccessible storage from absence without legacy lookup")
    func intentReaderFailures() throws {
        let empty = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        #expect(throws: RishiAppIntentRuntimeError.signedOut) { try RishiAppIntentRuntime.validatedPersistedIdentity(authority: empty) }
        let unavailable = SessionCredentialAuthority(persistence: AuthenticationUnavailablePersistence())
        #expect(throws: RishiAppIntentRuntimeError.credentialUnavailable) { try RishiAppIntentRuntime.validatedPersistedIdentity(authority: unavailable) }
    }

    #if DEBUG
    @Test("Debug reset refuses an old ticket and clears only the admitted canonical owner")
    func canonicalDebugReset() async throws {
        let fixture = try AuthenticationFixture(installedRawID: "A")
        defer { fixture.close() }
        let old = fixture.authority.attemptTicket()
        let box = CurrentUserBox()
        try await fixture.signIn("B", user: user("B"), into: box)
        let b = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        var preferenceOwners: [UUID] = []
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try RishiE2EConfiguration.beginCanonicalReset(dependencies: fixture.resources.dependencies,
                authority: fixture.authority, expectedTicket: old, clearPreferences: { preferenceOwners.append($0) })
        }
        #expect(preferenceOwners.isEmpty)
        #expect(fixture.storage.bytes == bytes)
        #expect(try fixture.authority.snapshot() == b)
        let owner = try RishiE2EConfiguration.beginCanonicalReset(dependencies: fixture.resources.dependencies,
            authority: fixture.authority, expectedTicket: b.ticket, clearPreferences: { preferenceOwners.append($0) })
        await owner.value
        #expect(preferenceOwners == [DerivedUserID.from("B")])
        #expect(throws: CredentialAuthenticationFailure.signedOut) { try fixture.authority.snapshot() }
    }
    #endif
}

@MainActor
private final class AuthenticationFixture {
    let storage = CredentialStagingMemoryPersistence()
    let authority: SessionCredentialAuthority
    let resources: CredentialIdentityFixture
    let consent: any CredentialDataUseConsentStore
    let adapter: CredentialAuthenticationAdapter
    let session: URLSession
    let effects = AuthenticationEffectRecorder()

    init(installedRawID: String? = nil, refreshToken: String? = "fixture-refresh",
         rehydrateInitialAuthority: Bool = false,
         phase: String? = nil, gate: CredentialStagingGate? = nil,
         cleanupGate: CredentialStagingGate? = nil) throws {
        let installedAuthority = SessionCredentialAuthority(persistence: storage)
        if let installedRawID {
            _ = try installedAuthority.install(session: Session(token: "access-\(installedRawID)", userId: installedRawID, email: nil),
                refreshToken: refreshToken, in: installedAuthority.beginTransition(expected: installedAuthority.attemptTicket()))
        }
        // Epoch is process-local, so equal-lease owner tests use two genuine
        // cold loads of the same persisted envelope, rather than comparing
        // a post-transition live authority with an epoch-zero cold load.
        let authority = rehydrateInitialAuthority ? SessionCredentialAuthority(persistence: storage) : installedAuthority
        if rehydrateInitialAuthority { _ = try authority.snapshot() }
        self.authority = authority
        let actualConsent = InMemoryDataUseConsentStore(credentialAuthority: authority)
        let consent = AuthenticationConsentGate(base: actualConsent, gate: phase == "consent" ? gate : nil)
        self.consent = consent
        let cleanupPause = Mutex(cleanupGate)
        resources = try CredentialIdentityFixture(authority: authority, cleanup: { tx in
            await cleanupPause.withLock { let gate = $0; $0 = nil; return gate }?.suspend()
            if let transition = tx.credentialTransition { _ = await actualConsent.clear(for: transition) }
        })
        let deps = resources.dependencies
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthenticationURLProtocol.self]
        session = URLSession(configuration: configuration)
        let worker = WorkerClient(baseURL: URL(string: "https://authentication.example.invalid")!, session: session,
            credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
            admitCredentialRejection: { code, context in await deps.admitCredentialRejection(code, context: context) })
        let oneShot = Mutex(gate)
        let effects = self.effects
        adapter = try CredentialAuthenticationAdapter(authority: authority, dependencies: deps, worker: worker, consent: consent,
            installSession: { session, refresh, tx in
                let installed = try await deps.installCredentialSession(session, refreshToken: refresh, in: tx)
                if phase == "install" { await oneShot.withLock { let gate = $0; $0 = nil; return gate }?.suspend() }
                return installed
            }, restoreIdentity: { try await deps.restoreCredentialIdentity($0) },
            registerPendingDeviceToken: { snapshot in
                if phase == "device" { await oneShot.withLock { let gate = $0; $0 = nil; return gate }?.suspend() }
                guard authority.performIfCurrent(snapshot.lease, mutation: { effects.record(snapshot.lease) }) else {
                    throw CredentialAuthenticationFailure.accountChanged
                }
            }, completeDebugOnboarding: { snapshot in
                guard authority.performIfCurrent(snapshot.lease, mutation: { effects.record(snapshot.lease) }) else {
                    throw CredentialAuthenticationFailure.accountChanged
                }
            }, refreshEntitlement: { snapshot in
                if phase == "entitlement" { await oneShot.withLock { let gate = $0; $0 = nil; return gate }?.suspend() }
                _ = authority.performIfCurrent(snapshot.lease, mutation: { effects.record(snapshot.lease) })
            })
    }

    func signIn(_ rawID: String, user: User, into box: CurrentUserBox) async throws {
        let attempt = adapter.beginAttempt()
        try await adapter.completeSignIn(session: Session(token: "access-\(rawID)", userId: rawID, email: user.email),
            refreshToken: nil, user: user, attempt: attempt, debugOnboarding: true) { box.signIn(user: user) }
    }
    func close() { session.invalidateAndCancel(); AuthenticationURLProtocol.reset() }
}

private final class AuthenticationEffectRecorder: Sendable {
    private let values = Mutex<[CredentialLease]>([])
    func record(_ lease: CredentialLease) { values.withLock { $0.append(lease) } }
    func snapshot() -> [CredentialLease] { values.withLock { $0 } }
}

private actor AuthenticationConsentGate: CredentialDataUseConsentStore {
    let base: InMemoryDataUseConsentStore
    private var gate: CredentialStagingGate?
    init(base: InMemoryDataUseConsentStore, gate: CredentialStagingGate?) { self.base = base; self.gate = gate }
    func bind(to lease: CredentialLease) async -> Bool {
        let captured = gate; gate = nil
        await captured?.suspend()
        return await base.bind(to: lease)
    }
    func record(for lease: CredentialLease) async -> ConsentRecord? { await base.record(for: lease) }
    func grant(for lease: CredentialLease) async -> Bool { await base.grant(for: lease) }
    func revoke(for lease: CredentialLease) async -> Bool { await base.revoke(for: lease) }
    func clear(for transition: CredentialTransition) async -> Bool { await base.clear(for: transition) }
    func setCurrentUser(_ userID: String?) async { await base.setCurrentUser(userID) }
    func record(for userID: String) async -> ConsentRecord? { await base.record(for: userID) }
    func grant(for userID: String) async { await base.grant(for: userID) }
    func revoke(for userID: String) async { await base.revoke(for: userID) }
    func clearCurrentUser() async { await base.clearCurrentUser() }
    func isCurrent(for userID: String) async -> Bool { await base.isCurrent(for: userID) }
}

private struct AuthenticationUnavailablePersistence: SessionCredentialPersistence {
    func readCanonical() throws -> Data? { throw CredentialStorageFailure.securityStatus(-25308) }
    func writeCanonical(_ data: Data) { Issue.record("Unavailable reader wrote credentials") }
    func readLegacy() -> LegacyCredentials { Issue.record("Unavailable reader fell back to legacy"); return .init(accessToken: nil, refreshToken: nil, userID: nil) }
    func removeLegacy() { Issue.record("Unavailable reader removed legacy credentials") }
}

private final class AuthenticationURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let status: Int
        let data: Data
        init(_ status: Int, _ json: String = "{}") { self.status = status; data = Data(json.utf8) }
        init(_ status: Int, _ data: Data) { self.status = status; self.data = data }
    }
    private struct State { var requests: [URLRequest] = []; var handler: (@Sendable (URLRequest) async throws -> Reply)? }
    private struct Loading { var stopped = false; var task: Task<Void, Never>? }
    private static let state = Mutex(State())
    private let loading = Mutex(Loading())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func setHandler(_ handler: @escaping @Sendable (URLRequest) async throws -> Reply) { state.withLock { $0 = State(handler: handler) } }
    static func reset() { state.withLock { $0 = State() } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "authentication.example.invalid" }
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
        loading.withLock { state in if state.stopped { task.cancel() } else { state.task = task } }
    }
    override func stopLoading() { loading.withLock { state in state.stopped = true; state.task?.cancel(); state.task = nil } }
}
