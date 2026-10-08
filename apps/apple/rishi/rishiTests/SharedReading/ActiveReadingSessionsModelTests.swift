import Foundation
import Synchronization
import Testing
@testable import rishi

@MainActor
@Suite("Active reading recovery ownership", .serialized, .timeLimit(.minutes(1)))
struct ActiveReadingSessionsModelTests {
    @Test("Stopped or retired list work cannot publish into a reopened sheet", arguments: ["stop", "account", "ABA"])
    func lateRefresh(_ mode: String) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        let gate = RecoveryGate()
        await fixture.http.setActiveGate(gate)
        let old = try fixture.model()
        let read = Task { await old.refresh(showError: true) }
        await gate.waitUntilEntered()
        old.stop()
        if mode != "stop" { try fixture.changeAccount(mode == "ABA" ? "A" : "B") }
        let replacement = try fixture.model()
        await gate.release()
        await read.value
        await replacement.refresh(showError: true)
        #expect(old.sessions.isEmpty && old.error == nil && !old.isLoading)
        #expect(replacement.sessions.map(\.sessionId) == ["room"])
        #expect(replacement.presentationID != old.presentationID)
    }

    @Test("Explicit list errors surface, periodic errors stay silent, success clears only list errors")
    func refreshErrorOrigin() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        let model = try fixture.model()
        await fixture.http.setActiveFailure(true)
        await model.refresh(showError: false)
        #expect(model.error == nil)
        await model.refresh(showError: true)
        #expect(model.error?.code == .bookHashMismatch)
        #expect(model.errorOrigin == .refresh)
        await fixture.http.setActiveFailure(false)
        await model.refresh(showError: true)
        #expect(model.error == nil && model.errorOrigin == nil)
        fixture.preparationError = SessionBookService.ServiceError.hashMismatch
        await model.join(fixture.summary)?.value
        #expect(model.errorOrigin == .join)
        await model.refresh(showError: true)
        #expect(model.error?.code == .bookHashMismatch && model.errorOrigin == .join)
        model.clearError()
        await model.refresh(showError: true) // The alert's retry only reloads.
        #expect(await fixture.http.rejoinCount == 0)
    }

    @Test("Preparation and hash failure never commit membership", arguments: [false, true])
    func preparationBeforeRejoin(_ wrongHash: Bool) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        if wrongHash { fixture.preparedHash = "different" }
        else { fixture.preparationError = SessionBookService.ServiceError.hashMismatch }
        let model = try fixture.model()
        await model.join(fixture.summary)?.value
        #expect(model.error?.code == .bookHashMismatch)
        #expect(model.busySessionID == nil)
        #expect(await fixture.http.rejoinCount == 0)
        #expect(await fixture.http.leaveHeaders.isEmpty)
        #expect(fixture.registry.activeHandleCount == 0)
    }

    @Test("Late admitted response retains A cleanup across stop, account change and model release", arguments: ["stop", "account", "ABA", "release"])
    func lateAdmission(_ mode: String) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        let gate = RecoveryGate()
        await fixture.http.setRejoinGate(gate)
        var old: ActiveReadingSessionsModel? = try fixture.model()
        weak var weakOld = old
        let work = try #require(old?.join(fixture.summary))
        await gate.waitUntilEntered()
        old?.stop()
        if mode == "account" || mode == "ABA" { try fixture.changeAccount(mode == "ABA" ? "A" : "B") }
        if mode == "release" { old = nil; #expect(weakOld == nil) }
        let replacement = try fixture.model()
        let replacementWork = try #require(replacement.join(fixture.otherSummary))
        await replacementWork.value
        #expect(replacement.error?.code == .sessionEnded)
        await gate.release()
        await work.value
        let headers = await fixture.http.leaveHeaders
        #expect(headers.filter { $0 == "Bearer fixture-A" }.count == (mode == "account" ? 1 : 2))
        #expect(await fixture.http.rejoinHeaders.first == "Bearer fixture-A")
        #expect(replacement.error?.code == .sessionEnded)
        #expect(replacement.dismissalRequest == nil && replacement.busySessionID == nil)
        #expect(await fixture.connectedCount() == 0)
        #expect(fixture.presentCalls == 0)
        #expect(fixture.registry.activeHandleCount == 0)
        #expect(old?.error == nil)
    }

    @Test("A refreshed successful admission compensates with its transmitted bearer after B installs")
    func refreshedAdmissionReceipt() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        let gate = RecoveryGate()
        await fixture.http.setRefreshFirstRejoin()
        await fixture.http.setRejoinGate(gate)
        let model = try fixture.model()
        let work = try #require(model.join(fixture.summary))
        await gate.waitUntilEntered()
        #expect(try fixture.authority.snapshot().tokenRevision == 1)
        model.stop()
        try fixture.changeAccount("B")
        let b = try fixture.authority.snapshot()
        await gate.release()
        await work.value
        #expect(await fixture.http.rejoinHeaders == ["Bearer fixture-A", "Bearer refreshed-A"])
        #expect(await fixture.http.leaveHeaders == ["Bearer refreshed-A"])
        #expect(await fixture.http.refreshCount == 1)
        #expect(try fixture.authority.snapshot() == b)
        #expect(model.error == nil && model.dismissalRequest == nil && model.busySessionID == nil)
    }

    @Test("A stale preparation cannot start rejoin or clear B busy work")
    func stalePreparation() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        let gate = RecoveryGate()
        fixture.preparationGate = gate
        let old = try fixture.model()
        let oldWork = try #require(old.join(fixture.summary))
        await gate.waitUntilEntered()
        old.stop()
        fixture.preparationGate = nil
        let newGate = RecoveryGate()
        await fixture.http.setRejoinGate(newGate)
        let replacement = try fixture.model()
        let newWork = try #require(replacement.join(fixture.summary))
        await newGate.waitUntilEntered()
        await gate.release()
        await oldWork.value
        #expect(replacement.busySessionID == "room")
        #expect(replacement.error == nil && replacement.dismissalRequest == nil)
        await newGate.release()
        await newWork.value
        #expect(await fixture.http.rejoinCount == 1)
    }

    @Test("Duplicate protection before preparation, after response and after setup sends no leave", arguments: ["before", "response", "setup"])
    func duplicateRoom(_ boundary: String) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        await fixture.http.setAdmissionStatus("active")
        let model = try fixture.model()
        if boundary == "before" {
            fixture.activeRoom = "room"
            #expect(model.join(fixture.summary) == nil)
        } else {
            let gate = RecoveryGate()
            if boundary == "response" { await fixture.http.setRejoinGate(gate) }
            else { fixture.runtimeGate = gate }
            let work = try #require(model.join(fixture.summary))
            await gate.waitUntilEntered()
            fixture.activeRoom = "room"
            await gate.release()
            await work.value
        }
        #expect(await fixture.http.leaveHeaders.isEmpty)
        #expect(fixture.presentCalls == 0)
        #expect(fixture.registry.activeHandleCount == 0)
        let request = try #require(model.dismissalRequest)
        #expect(request == model.presentationID)
        #expect(!model.takeDismissal(UUID()))
        #expect(model.takeDismissal(request))
        #expect(!model.takeDismissal(request))
    }

    @Test("Registry claim during suspended setup remains the sole remote leave owner")
    func registryDrainDuringSetup() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        await fixture.http.setAdmissionStatus("active")
        let gate = RecoveryGate()
        fixture.runtimeGate = gate
        let model = try fixture.model()
        let work = try #require(model.join(fixture.summary))
        await gate.waitUntilEntered()
        #expect(fixture.registry.activeHandleCount == 1)
        model.stop()
        try fixture.changeAccount("B")
        await fixture.registry.drain(accountID: DerivedUserID.from("A"))
        await gate.release()
        await work.value
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(fixture.registry.activeHandleCount == 0)
        #expect(fixture.presentCalls == 0 && model.error == nil && model.dismissalRequest == nil)
    }

    @Test("Ended, failed setup, and rejected presentation compensate before current publication", arguments: ["ended", "setup", "presentation"])
    func failedAdmission(_ failure: String) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        if failure != "ended" { await fixture.http.setAdmissionStatus("active") }
        if failure == "setup" { fixture.runtimeError = SharedReadingError.from(code: .sessionEnded) }
        let model = try fixture.model()
        await model.join(fixture.summary)?.value
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(fixture.registry.activeHandleCount == 0 && model.busySessionID == nil)
        #expect(model.dismissalRequest == nil)
        if failure == "presentation" {
            #expect(fixture.presentCalls == 1 && model.error == nil)
        } else { #expect(model.error?.code == .sessionEnded && model.errorOrigin == .join) }
    }

    @Test("Late reconnect keeps the concrete runtime's durable leave witness", arguments: [false, true])
    func lateReconnectReceipt(_ registryOwnsLeave: Bool) async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        fixture.presentationAccepted = true
        await fixture.http.setAdmissionStatus("active")
        var model: ActiveReadingSessionsModel? = try fixture.model()
        await model?.join(fixture.summary)?.value
        let runtime = try #require(fixture.presentedRuntime)
        #expect(runtime.readerContext != nil && runtime.canRefreshAdmission)
        let transport = try #require(fixture.transports.last)
        let gate = RecoveryGate()
        await fixture.http.setRejoinGate(gate)
        let reconnect = Task { try await transport.refreshAdmission() }
        await gate.waitUntilEntered()
        model?.stop()
        model = nil
        fixture.presentedRuntime = nil
        if registryOwnsLeave {
            try fixture.changeAccount("B")
            await fixture.registry.drain(accountID: DerivedUserID.from("A"))
            #expect(runtime.isRegistryDrainRemoteLeaveOwned)
        } else { await runtime.closeLocally() }
        await gate.release()
        await #expect(throws: SharedReadingError.from(code: .accountChanged)) { try await reconnect.value }
        #expect(await fixture.http.rejoinHeaders == ["Bearer fixture-A", "Bearer fixture-A"])
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
        #expect(fixture.registry.activeHandleCount == 0)
    }

    @Test("A closed or released runtime rejects reconnect before a fresh admission request")
    func closedReconnectDoesNotTransmit() async throws {
        let fixture = try RecoveryFixture()
        defer { fixture.close() }
        await fixture.http.setAdmissionStatus("active")
        fixture.runtimeError = SharedReadingError.from(code: .sessionEnded)
        let model = try fixture.model()
        await model.join(fixture.summary)?.value
        let transport = try #require(fixture.transports.last)
        await #expect(throws: SharedReadingError.from(code: .accountChanged)) { try await transport.refreshAdmission() }
        #expect(await fixture.http.rejoinCount == 1)
        #expect(await fixture.http.leaveHeaders == ["Bearer fixture-A"])
    }
}

@MainActor
private final class RecoveryFixture {
    let authority: SessionCredentialAuthority
    let http = RecoveryHTTP()
    let registry = SharedReadingSessionRegistry()
    let host = UUID().uuidString.lowercased() + ".invalid"
    let session: URLSession
    var snapshot: CredentialSnapshot
    var identity: LibraryAccountIdentity
    var activeRoom: String?
    var preparationError: Error?
    var preparationGate: RecoveryGate?
    var preparedHash = "hash"
    var runtimeGate: RecoveryGate?
    var runtimeError: SharedReadingError?
    var transports: [RecoveryTransport] = []
    var presentCalls = 0
    var presentationAccepted = false
    var presentedRuntime: SharedReadingSessionRuntime?

    init() throws {
        let authority = SessionCredentialAuthority(persistence: CredentialStagingMemoryPersistence())
        self.authority = authority
        snapshot = try installStagingCredentials("A", authority: authority)
        identity = LibraryAccountIdentity(userID: DerivedUserID.from("A"), generation: 1)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryURLProtocol.self]
        session = URLSession(configuration: configuration)
        RecoveryURLProtocol.install(host: host, http: http)
    }

    func close() {
        if let runtime = presentedRuntime { Task { await runtime.closeLocally() } }
        presentedRuntime = nil
        session.invalidateAndCancel()
        RecoveryURLProtocol.remove(host: host)
    }

    func changeAccount(_ rawID: String) throws {
        snapshot = try installStagingCredentials(rawID, authority: authority)
        identity = LibraryAccountIdentity(userID: DerivedUserID.from(rawID), generation: identity.generation + 1)
    }

    var summary: SharedReadingSessionSummary { summary("room") }
    var otherSummary: SharedReadingSessionSummary { summary("other") }
    private func summary(_ id: String) -> SharedReadingSessionSummary {
        let json = "{\"sessionId\":\"\(id)\",\"status\":\"active\",\"book\":{\"bookId\":\"book\",\"contentHash\":\"hash\",\"format\":\"epub\",\"fileSize\":1,\"downloadURL\":\"https://\(host)/book\"},\"controllerUserId\":\"A\",\"joinedAt\":0}"
        return try! JSONDecoder().decode(SharedReadingSessionSummary.self, from: Data(json.utf8))
    }

    func connectedCount() async -> Int {
        var count = 0
        for transport in transports { count += await transport.connectedCount }
        return count
    }

    func model() throws -> ActiveReadingSessionsModel {
        let expected = identity
        let worker = WorkerClient(baseURL: URL(string: "https://\(host)")!, session: session,
            credentialAuthority: authority, dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
            admitCredentialRejection: { _, _ in .stale })
        let api = try SharedReadingAPI(baseURL: URL(string: "https://\(host)")!, session: session,
            credentialAuthority: authority, workerClient: worker, credentialContext: .normal(snapshot.lease))
        return try ActiveReadingSessionsModel(api: api, sessionRegistry: registry,
            credentialSnapshot: snapshot, credentialAuthority: authority, accountIdentity: expected,
            currentAccountIdentity: { [weak self] in self?.identity },
            prepareBook: { [self] _ in
                if let preparationGate { await preparationGate.suspend() }
                if let preparationError { throw preparationError }
                return SessionBookService.PreparedBook(book: Book(userId: expected.userID,
                    title: "Fixture", formatType: .epub, fileURL: "fixture.epub"), contentHash: preparedHash)
            },
            makeTransport: { [self] in
                let transport = RecoveryTransport(gate: runtimeGate, failure: runtimeError)
                transports.append(transport)
                return transport
            },
            presentReader: { [self] context in
                presentCalls += 1
                #expect(context.runtime.readerContext != nil)
                #expect(context.runtime.requiresAuthoritativeRecovery)
                if presentationAccepted { presentedRuntime = context.runtime }
                return presentationAccepted
            },
            isActiveReader: { [weak self] sessionID, ownerID in
                self?.activeRoom == sessionID && self?.identity.userID == ownerID
            })
    }
}

private actor RecoveryHTTP {
    var rejoinCount = 0
    var rejoinHeaders: [String] = []
    var leaveHeaders: [String] = []
    private var activeGate: RecoveryGate?
    private var rejoinGate: RecoveryGate?
    private var activeFailure = false
    private var status = "ended"
    private var refreshFirstRejoin = false
    private(set) var refreshCount = 0
    func setActiveGate(_ gate: RecoveryGate) { activeGate = gate }
    func setRejoinGate(_ gate: RecoveryGate) { rejoinGate = gate }
    func setActiveFailure(_ value: Bool) { activeFailure = value }
    func setAdmissionStatus(_ value: String) { status = value }
    func setRefreshFirstRejoin() { refreshFirstRejoin = true }

    func response(_ request: URLRequest) async -> (Int, Data) {
        let path = request.url!.path
        if path == "/auth/refresh" {
            refreshCount += 1
            return (200, Data(#"{"accessToken":"refreshed-A","refreshToken":"refresh-A","userId":"A"}"#.utf8))
        }
        if path.hasSuffix("/active") {
            let gate = activeGate; activeGate = nil
            if let gate { await gate.suspend() }
            if activeFailure { return (409, Data(#"{"error":"Mismatch","code":"BOOK_HASH_MISMATCH"}"#.utf8)) }
            return (200, Data(#"{"sessions":[{"sessionId":"room","status":"active","book":{"bookId":"book","contentHash":"hash","format":"epub","fileSize":1,"downloadURL":"https://fixture.invalid/book"},"controllerUserId":"A","joinedAt":0}]}"#.utf8))
        }
        if path.hasSuffix("/rejoin") {
            rejoinCount += 1
            rejoinHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            if refreshFirstRejoin {
                refreshFirstRejoin = false
                return (401, Data(#"{"error":"Unauthorized"}"#.utf8))
            }
            let gate = rejoinGate; rejoinGate = nil
            if let gate { await gate.suspend() }
            return (200, Data("{\"admissionTicket\":\"ticket\",\"wsUrl\":\"wss://fixture.invalid/socket\",\"roomEpoch\":1,\"connectionGeneration\":1,\"status\":\"\(status)\"}".utf8))
        }
        if path.hasSuffix("/leave") {
            leaveHeaders.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            let id = path.split(separator: "/").dropLast().last ?? "room"
            return (200, Data("{\"sessionId\":\"\(id)\",\"status\":\"ended\",\"roomEpoch\":1,\"controllerGeneration\":1,\"controllerUserId\":\"A\"}".utf8))
        }
        if path.hasSuffix("/turn") {
            return (200, Data(#"{"iceServers":[]}"#.utf8))
        }
        if path.hasSuffix("/room") {
            return (200, Data(#"{"sessionId":"room","status":"active","roomEpoch":1,"controllerGeneration":1,"controllerUserId":"A","maxParticipants":4,"participants":[],"removedUserIds":[]}"#.utf8))
        }
        return (404, Data(#"{"error":"Unexpected fixture request"}"#.utf8))
    }
}

private actor RecoveryGate {
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
private actor RecoveryTransport: SharedReadingSignalingTransport {
    nonisolated let events: AsyncStream<SharedReadingSignalingEvent>
    private let continuation: AsyncStream<SharedReadingSignalingEvent>.Continuation
    private let gate: RecoveryGate?
    private let failure: SharedReadingError?
    private(set) var connectedCount = 0
    private var admissionRefresh: (@Sendable () async throws -> SharedReadingAdmission)?

    init(gate: RecoveryGate?, failure: SharedReadingError?) {
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

private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let handlers = Mutex<[String: RecoveryHTTP]>([:])
    private let loadingTask = Mutex<Task<Void, Never>?>(nil)
    static func install(host: String, http: RecoveryHTTP) { handlers.withLock { $0[host] = http } }
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
