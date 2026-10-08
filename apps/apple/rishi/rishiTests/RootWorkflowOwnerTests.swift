import Foundation
import Synchronization
import Testing
@testable import rishi

@MainActor
@Suite("Root workflow ownership", .serialized, .timeLimit(.minutes(1)))
struct RootWorkflowOwnerTests {
    @Test("Late redeem retains exact A compensation across retirement, replacement and root release",
          arguments: ["retire", "account", "ABA", "release"])
    func lateReceipt(_ mode: String) async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let gate = RootWorkflowGate()
        await fixture.http.setRedeemGate(gate)
        var owner: RootWorkflowOwner? = try fixture.owner()
        weak var weakOwner = owner
        let work = try #require(fixture.queue("original", owner: owner))
        defer { Task { await gate.release() } }
        await gate.waitUntilEntered()
        if mode == "account" || mode == "ABA" {
            try await fixture.changeAccount(mode == "account" ? "B" : "A")
            // This case isolates the ORIGINAL A receipt, not a newly eligible retry.
            owner?.updateEligibility(identity: fixture.identity, onboardingPresented: true)
        } else { owner?.retire() }
        if mode == "release" { owner = nil; #expect(weakOwner == nil) }
        let currentBytes = fixture.storage.bytes
        let current = try fixture.authority.snapshot()
        await gate.release()
        await work.value
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(await fixture.http.redeemHeaders == ["Bearer fixture-A"])
        #expect(fixture.storage.bytes == currentBytes)
        #expect(try fixture.authority.snapshot() == current)
        #expect(owner?.alertMessage == nil)
        #expect(fixture.router.sharedReaderRoute == nil)
        #expect(fixture.preparations == 0 && fixture.transports.isEmpty)
        #expect(fixture.registry.activeHandleCount == 0)
    }

    @Test("An old attempt cannot erase a newer token or its retryable error")
    func supersededToken() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let gate = RootWorkflowGate()
        await fixture.http.setRedeemGate(gate)
        let owner = try fixture.owner()
        let old = try #require(fixture.queue("original", owner: owner))
        defer { Task { await gate.release() } }
        await gate.waitUntilEntered()
        let replacement = try #require(fixture.queue("retryable", owner: owner))
        await replacement.value
        let error = try #require(owner.alertMessage)
        #expect(owner.pendingToken == "retryable")
        #expect(!owner.isRedeeming)
        await gate.release()
        await old.value
        #expect(owner.pendingToken == "retryable" && owner.alertMessage == error)
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(await fixture.http.redeemHeaders.count == 2)
        #expect(!owner.isRedeeming && fixture.preparations == 0)
    }

    @Test("Identical input coalesces, while retirement rejects every later queue")
    func coalescesCurrentInput() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let gate = RootWorkflowGate()
        await fixture.http.setRedeemGate(gate)
        let owner = try fixture.owner()
        let work = try #require(fixture.queue("original", owner: owner))
        defer { Task { await gate.release() } }
        await gate.waitUntilEntered()
        let duplicate = try #require(fixture.queue("original", owner: owner))
        owner.retire()
        #expect(fixture.queue("new", owner: owner) == nil)
        await gate.release()
        await work.value
        await duplicate.value
        #expect(await fixture.http.redeemHeaders.count == 1)
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
    }

    @Test("Preparation or hash failure compensates once and never admits signaling", arguments: [false, true])
    func preparationFailure(_ hashMismatch: Bool) async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        if hashMismatch { fixture.preparedHash = "wrong" }
        else { fixture.preparationError = SessionBookService.ServiceError.hashMismatch }
        let owner = try fixture.owner()
        await fixture.queue("original", owner: owner)?.value
        #expect(owner.alertMessage != nil)
        #expect(fixture.preparations == 1 && fixture.transports.isEmpty)
        #expect(await fixture.http.readyCount == 0)
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(fixture.registry.activeHandleCount == 0)
        #expect(owner.pendingToken == "original")
        if hashMismatch {
            let policy = SharedReadingError.from(code: .bookHashMismatch)
            #expect(policy.retryable && policy.action == .removeAndRetry)
        }
    }

    @Test("A preparation finishing after root retirement cannot start book admission")
    func latePreparation() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let gate = RootWorkflowGate()
        fixture.preparationGate = gate
        let owner = try fixture.owner()
        let work = try #require(fixture.queue("original", owner: owner))
        defer { Task { await gate.release() } }
        await gate.waitUntilEntered()
        owner.retire()
        await gate.release()
        await work.value
        #expect(await fixture.http.readyCount == 0)
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(owner.alertMessage == nil && fixture.registry.activeHandleCount == 0)
    }

    @Test("Explicit session input survives a later startup load and retirement blocks later reads")
    func startupPendingInput() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        await fixture.pending.save(token: "older")
        let owner = try fixture.owner(onboarding: true)
        #expect(fixture.queue("newer", owner: owner) == nil)
        await owner.loadPendingIfEligible()
        #expect(owner.pendingToken == "newer")
        #expect(await fixture.http.redeemHeaders.isEmpty)
        owner.retire()
        #expect(fixture.queue("retired", owner: owner) == nil)
        await owner.loadPendingIfEligible()
        #expect(await fixture.pending.load() == "older")
    }

    @Test("Original invitation and actual runtime route are retained; duplicate same room never leaves")
    func actualRouteAndDuplicate() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let owner = try fixture.owner()
        await fixture.pending.save(token: "original")
        owner.queueInvitation(SharedReadingInvitation(sessionID: "room", shareURL: URL(string: "https://fixture.invalid/invite")!),
                              identity: fixture.identity)
        await fixture.queue("original", owner: owner)?.value
        #expect(owner.pendingToken == nil && !owner.hasPendingInvitation)
        #expect(await fixture.pending.load() == nil)
        let route = try #require(fixture.router.sharedReaderRoute)
        let presentation = try #require(fixture.router.sharedReaderPresentation(for: route, accountID: fixture.identity.userID))
        #expect(presentation.context.runtime.readerContext != nil)
        #expect(fixture.registry.activeHandleCount == 1)
        #expect(await fixture.http.leaveHeaders.isEmpty)
        await fixture.queue("duplicate", owner: owner)?.value
        #expect(fixture.router.sharedReaderRoute?.id == route.id)
        #expect(fixture.preparations == 1 && fixture.transports.count == 1)
        #expect(await fixture.http.leaveHeaders.isEmpty)
        await presentation.context.runtime.closeLocally()
    }

    @Test("A room opened during preparation survives final replacement admission")
    func sameRoomOpenedDuringPreparation() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let gate = RootWorkflowGate()
        fixture.preparationGate = gate
        let pendingOwner = try fixture.owner()
        let pending = try #require(fixture.queue("original", owner: pendingOwner))
        defer { Task { await gate.release() } }
        await gate.waitUntilEntered()
        let currentOwner = try fixture.owner()
        await fixture.queue("current", owner: currentOwner)?.value
        let original = try #require(fixture.router.sharedReaderRoute)
        let originalPresentation = try #require(fixture.router.sharedReaderPresentation(
            for: original, accountID: fixture.identity.userID))
        #expect(originalPresentation.context.runtime.readerContext != nil)
        #expect(fixture.registry.activeHandleCount == 1)
        await gate.release()
        await pending.value
        #expect(fixture.router.sharedReaderRoute?.id == original.id)
        #expect(fixture.router.sharedReaderPresentation(for: original, accountID: fixture.identity.userID)?
            .context.runtime === originalPresentation.context.runtime)
        #expect(originalPresentation.context.runtime.readerContext != nil)
        #expect(pendingOwner.pendingToken == nil && pendingOwner.alertMessage == nil)
        #expect(fixture.preparations == 2 && fixture.transports.count == 2)
        #expect(fixture.registry.activeHandleCount == 1)
        #expect(await fixture.http.leaveHeaders.isEmpty)
        await originalPresentation.context.runtime.closeLocally()
    }

    @Test("Required nil router provider denies actual context without an ambient fallback")
    func explicitNilProvider() async throws {
        let fixture = try RootWorkflowFixture(routerHasIdentity: false)
        defer { fixture.finish() }
        let owner = try fixture.owner()
        await fixture.queue("original", owner: owner)?.value
        #expect(owner.pendingToken == nil && owner.alertMessage != nil)
        #expect(fixture.router.sharedReaderRoute == nil)
        #expect(fixture.registry.activeHandleCount == 0)
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(fixture.preparations == 1 && fixture.transports.count == 1)
    }

    @Test("Root delegates restore to the existing canonical adapter and preserves transient recovery")
    func canonicalRestore() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let owner = try fixture.owner()
        let original = try fixture.authority.snapshot()
        let bytes = fixture.storage.bytes
        fixture.box.signout()
        await fixture.http.setUserFailure(true)
        await owner.restoreAndLoadPendingIfEligible()
        guard case .authenticationRecovery(let recovery) = fixture.box.state else {
            Issue.record("Temporary failure did not preserve recovery"); return
        }
        #expect(recovery.kind == .temporarilyUnavailable)
        #expect(fixture.storage.bytes == bytes)
        #expect(try fixture.authority.snapshot() == original)
        #expect(owner.pendingToken == nil && owner.alertMessage == nil)
        await fixture.http.setUserFailure(false)
        await owner.restoreAndLoadPendingIfEligible()
        guard case .signedIn(let restored) = fixture.box.state else {
            Issue.record("Canonical retry did not restore"); return
        }
        #expect(restored.id == DerivedUserID.from("A"))
        #expect(owner.identity == fixture.identity)
        #expect(fixture.storage.bytes == bytes && fixture.registry.activeHandleCount == 0)
        #expect(try fixture.authority.snapshot() == original)
    }

    @Test("Root fence detaches immediately; captured concrete Host cleanup survives retirement")
    func drainCleanupSurvivesRetirement() async throws {
        let fixture = try RootWorkflowFixture()
        defer { fixture.finish() }
        let owner = try fixture.owner()
        owner.start(); owner.start()
        await fixture.queue("original", owner: owner)?.value
        let route = try #require(fixture.router.sharedReaderRoute)
        var presentation = fixture.router.sharedReaderPresentation(for: route, accountID: fixture.identity.userID)
        weak var retainedRuntime = presentation?.context.runtime
        #expect(retainedRuntime != nil)
        presentation = nil
        // This is the SAME finite Host callback used by owner.start(). Memory
        // AppDependencies cannot exercise its services-present delivery branch.
        let capturedCleanup = fixture.host.cleanupAfterDrain
        let original = try fixture.authority.snapshot()
        let transaction = try fixture.dependencies.beginAccountChange(expectedCredentialTicket: original.ticket)
        #expect(fixture.router.sharedReaderRoute == nil)
        owner.retire(); owner.retire()
        await transaction.drain.value
        await fixture.registry.drain(accountID: route.accountID)
        #expect(fixture.registry.activeHandleCount == 0)
        #expect(retainedRuntime != nil, "Detached router context must survive registry drain until Host cleanup")
        await capturedCleanup(route.accountID)
        #expect(retainedRuntime == nil, "Captured Host cleanup must release the actual detached context after retirement")
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(fixture.queue("later", owner: owner) == nil)
    }
}

@MainActor
private final class RootWorkflowFixture {
    let storage = CredentialStagingMemoryPersistence()
    let authority: SessionCredentialAuthority
    let dependencies: AppDependencies
    let authentication: CredentialAuthenticationAdapter
    let box = CurrentUserBox()
    let registry = SharedReadingSessionRegistry()
    let router: AppRouter
    let host: RootWorkflowOwner.Host
    let http = RootWorkflowHTTP()
    let pending: PendingSessionInviteStore
    let session: URLSession
    let hostName = UUID().uuidString.lowercased() + ".invalid"
    let defaults: UserDefaults
    let packages: SharePackageService
    var preparations = 0
    var preparedHash = "hash"
    var preparationError: Error?
    var preparationGate: RootWorkflowGate?
    var transports: [RootWorkflowTransport] = []
    private var admittedTasks: [Task<Void, Never>] = []

    var identity: LibraryAccountIdentity { dependencies.activeAccountIdentity! }

    init(routerHasIdentity: Bool = true) throws {
        let authority = SessionCredentialAuthority(persistence: storage)
        self.authority = authority
        _ = try installStagingCredentials("A", authority: authority)
        let actual = try CredentialIdentityFixture(authority: authority, ownerID: DerivedUserID.from("A"))
        let deps = actual.dependencies
        dependencies = deps
        let router = AppRouter(sharedReaderAccountIDProvider: { routerHasIdentity ? deps.cachedUserId : nil })
        self.router = router
        #if targetEnvironment(macCatalyst)
        host = RootWorkflowOwner.Host(router: router, readerWindows: ReaderWindowCoordinator())
        #else
        host = RootWorkflowOwner.Host(router: router)
        #endif
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RootWorkflowURLProtocol.self]
        let session = URLSession(configuration: config)
        self.session = session
        RootWorkflowURLProtocol.install(host: hostName, http: http)
        let worker = WorkerClient(baseURL: URL(string: "https://\(hostName)")!, session: session,
            credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
            admitCredentialRejection: { _, _ in .stale })
        let consent = InMemoryDataUseConsentStore(credentialAuthority: authority)
        authentication = try CredentialAuthenticationAdapter(authority: authority, dependencies: deps,
            worker: worker, consent: consent,
            installSession: { try await deps.installCredentialSession($0, refreshToken: $1, in: $2) },
            restoreIdentity: { try await deps.restoreCredentialIdentity($0) },
            registerPendingDeviceToken: { snapshot in
                guard authority.isCurrent(snapshot.lease) else { throw CredentialAuthenticationFailure.accountChanged }
            }, completeDebugOnboarding: { snapshot in
                guard authority.isCurrent(snapshot.lease) else { throw CredentialAuthenticationFailure.accountChanged }
            }, refreshEntitlement: { _ in })
        box.signIn(user: User(id: DerivedUserID.from("A"), email: nil, name: "A"))
        let suffix = UUID().uuidString
        pending = PendingSessionInviteStore(accountId: "fixture-\(suffix)")
        defaults = UserDefaults(suiteName: "root-workflow-\(suffix)")!
        let bookStore = InMemoryBookStore()
        let fileStorage = BookFileStorage(rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(suffix),
                                          bookStore: bookStore, coverExtractors: [:])
        packages = SharePackageService(workerClient: worker, bookStore: bookStore, fileStorage: fileStorage,
            urlSession: session, pendingStore: PendingShareStore(defaults: defaults, key: "fixture-packages"),
            currentUserId: { await deps.cachedUserId }, syncBeforeCreate: {}, markBookDirty: { _ in })
    }

    func owner(onboarding: Bool = false) throws -> RootWorkflowOwner {
        let deps = dependencies
        let authority = authority
        let resources = RootWorkflowOwner.Resources(packages: packages,
            prepareBook: { [self] _, userID in
                preparations += 1
                let gate = preparationGate
                preparationGate = nil
                if let gate { await gate.suspend() }
                if let preparationError { throw preparationError }
                return SessionBookService.PreparedBook(book: Book(userId: userID, title: "Fixture",
                    formatType: .epub, fileURL: "fixture.epub"), contentHash: preparedHash)
            }, api: { [session, hostName] context in
                let worker = WorkerClient(baseURL: URL(string: "https://\(hostName)")!, session: session,
                    credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
                    admitCredentialRejection: { _, _ in .stale })
                return try SharedReadingAPI(baseURL: URL(string: "https://\(hostName)")!, session: session,
                    credentialAuthority: authority, workerClient: worker, credentialContext: context)
            }, registry: registry, pendingInvites: pending, makeTransport: { [self] in
                let transport = RootWorkflowTransport()
                transports.append(transport)
                return transport
            })
        let owner = try RootWorkflowOwner(dependencies: deps, authentication: authentication, currentUser: box,
                                         resources: resources, host: host)
        owner.updateEligibility(identity: identity, onboardingPresented: onboarding)
        return owner
    }

    func changeAccount(_ rawID: String) async throws {
        let snapshot = try authority.snapshot()
        let transaction = try dependencies.beginAccountChange(expectedCredentialTicket: snapshot.ticket)
        _ = try await dependencies.installCredentialSession(Session(token: "fixture-\(rawID)", userId: rawID, email: nil),
            refreshToken: "fixture-refresh-\(rawID)", in: transaction)
        box.signIn(user: User(id: DerivedUserID.from(rawID), email: nil, name: rawID))
    }

    @discardableResult
    func queue(_ token: String, owner: RootWorkflowOwner?) -> Task<Void, Never>? {
        let work = owner?.queueSessionToken(token)
        if let work { admittedTasks.append(work) }
        return work
    }

    func finish() {
        // Retain the fixture/session until EVERY admitted attempt and actual
        // registry cleanup finishes, including a throwing test's early exit.
        Task { @MainActor [self] in
            for work in admittedTasks { await work.value }
            admittedTasks.removeAll()
            await pending.clear()
            await registry.drain(accountID: DerivedUserID.from("A"))
            session.invalidateAndCancel()
            RootWorkflowURLProtocol.remove(host: hostName)
            defaults.removeObject(forKey: "fixture-packages")
        }
    }

}

private actor RootWorkflowHTTP {
    private var gate: RootWorkflowGate?
    private var userFailure = false
    func setUserFailure(_ value: Bool) { userFailure = value }
    private(set) var redeemHeaders: [String] = []
    private(set) var leaveHeaders: [String] = []
    private(set) var readyCount = 0
    func setRedeemGate(_ gate: RootWorkflowGate) { self.gate = gate }
    private static func bodyData(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    func response(_ request: URLRequest) async -> (Int, Data) {
        let path = request.url!.path
        if path == "/api/user" {
            if userFailure { return (503, Data(#"{"error":"Temporary","code":"SERVICE_UNAVAILABLE"}"#.utf8)) }
            return (200, try! JSONEncoder().encode(User(id: DerivedUserID.from("A"), email: nil, name: "A")))
        }
        if path.hasSuffix("/redeem") {
            redeemHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let body = try? JSONSerialization.jsonObject(with: Self.bodyData(request)) as? [String: String]
            if body?["token"] == "retryable" { return (503, Data(#"{"error":"Temporary","code":"SERVICE_UNAVAILABLE"}"#.utf8)) }
            let captured = gate; gate = nil
            if let captured { await captured.suspend() }
            return (200, Data(#"{"inviteId":"invite","sessionId":"room","book":{"bookId":"book","contentHash":"hash","format":"epub","fileSize":1,"downloadURL":"https://fixture.invalid/book"},"status":"active","redemptionId":"redemption"}"#.utf8))
        }
        if path.hasSuffix("/book-ready") {
            readyCount += 1
            return (200, Data(#"{"admissionTicket":"ticket","wsUrl":"wss://fixture.invalid/socket","roomEpoch":1,"connectionGeneration":1,"status":"active"}"#.utf8))
        }
        if path.hasSuffix("/leave") {
            leaveHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (200, Data(#"{"sessionId":"room","status":"ended","roomEpoch":1,"controllerGeneration":1,"controllerUserId":"A"}"#.utf8))
        }
        if path.hasSuffix("/turn") { return (200, Data(#"{"iceServers":[]}"#.utf8)) }
        if path.hasSuffix("/room") {
            return (200, Data(#"{"sessionId":"room","status":"active","roomEpoch":1,"controllerGeneration":1,"controllerUserId":"A","maxParticipants":4,"participants":[],"removedUserIds":[]}"#.utf8))
        }
        return (404, Data(#"{"error":"Unexpected fixture request"}"#.utf8))
    }
}

private actor RootWorkflowGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
        await withTaskCancellationHandler {
            if !released && !Task.isCancelled {
                await withCheckedContinuation { waiters.append($0) }
            }
        } onCancel: { Task { await self.release() } }
    }
    func waitUntilEntered() async {
        await withTaskCancellationHandler {
            if !entered && !Task.isCancelled {
                await withCheckedContinuation { entryWaiters.append($0) }
            }
        } onCancel: { Task { await self.cancelEntryWaiters() } }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
    }
    private func cancelEntryWaiters() {
        entryWaiters.forEach { $0.resume() }; entryWaiters.removeAll()
    }
}

/// Existing signaling port, concrete real runtime/coordinator. No socket,
/// remote peer, microphone capture or RTC connection is opened by this fake.
private actor RootWorkflowTransport: SharedReadingSignalingTransport {
    nonisolated let events: AsyncStream<SharedReadingSignalingEvent>
    private let continuation: AsyncStream<SharedReadingSignalingEvent>.Continuation
    private let gate: RootWorkflowGate?
    private let failure: SharedReadingError?
    private(set) var connectedCount = 0
    private var admissionRefresh: (@Sendable () async throws -> SharedReadingAdmission)?

    init(gate: RootWorkflowGate? = nil, failure: SharedReadingError? = nil) {
        let pair = AsyncStream<SharedReadingSignalingEvent>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.gate = gate
        self.failure = failure
    }

    func connect(admission: SharedReadingAdmission, bearerToken: String,
                 refreshAdmission: (@Sendable () async throws -> SharedReadingAdmission)?,
                 refreshBearerToken: (@Sendable () async throws -> String)?) async throws {
        connectedCount += 1
        admissionRefresh = refreshAdmission
        if let gate { await gate.suspend() }
        if let failure { throw failure }
        continuation.yield(.sessionState(.init(sessionId: "room", roomEpoch: 1,
            controllerGeneration: 1, connectionGeneration: 1, status: .active, controllerUserId: "A")))
        continuation.yield(.participantRoster(.init(sessionId: "room", roomEpoch: 1,
            controllerGeneration: 1, connectionGeneration: 1, rosterGeneration: 1, participants: [])))
        continuation.yield(.syncAbsent(.init(sessionId: "room", roomEpoch: 1,
            controllerGeneration: 1, connectionGeneration: 1)))
    }
    func disconnect() async { continuation.finish() }
    func send(_ message: SharedReadingSignalingOutgoingMessage) async throws {}
    func refreshAdmission() async throws -> SharedReadingAdmission {
        guard let admissionRefresh else { throw SharedReadingError.from(code: .admissionRequired) }
        return try await admissionRefresh()
    }
}

private final class RootWorkflowURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handlers = Mutex<[String: RootWorkflowHTTP]>([:])
    private let loadingTask = Mutex<Task<Void, Never>?>(nil)
    static func install(host: String, http: RootWorkflowHTTP) { handlers.withLock { $0[host] = http } }
    static func remove(host: String) { handlers.withLock { $0.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        handlers.withLock { $0[request.url?.host ?? ""] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let http = Self.handlers.withLock({ $0[request.url?.host ?? ""] }) else { return }
        let work = Task { @Sendable [self] in
            let (status, data) = await http.response(request)
            guard !Task.isCancelled else { return }
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        loadingTask.withLock { $0 = work }
    }
    override func stopLoading() { loadingTask.withLock { $0?.cancel(); $0 = nil } }
}
