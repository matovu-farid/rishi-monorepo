import Foundation
import Synchronization
import Testing
@testable import rishi

@MainActor
@Suite("Inactive voice lifecycle credential ownership", .serialized, .timeLimit(.minutes(1)))
struct VoiceCredentialOwnershipTests {
    private let baseURL = URL(string: "https://voice-ownership.example.invalid")!
    private func install(_ owner: String, in authority: SessionCredentialAuthority) throws -> CredentialSnapshot {
        let transition = try authority.beginTransition(expected: authority.attemptTicket())
        return try authority.install(session: Session(token: "access-\(owner)", userId: owner, email: nil,
                                                      issuedAt: Date(timeIntervalSince1970: 1), expiresAt: nil),
                                     refreshToken: "refresh-\(owner)", in: transition)
    }
    private func transport() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [VoiceOwnershipURLProtocol.self]
        return URLSession(configuration: config)
    }
    private func worker(_ authority: SessionCredentialAuthority, _ transport: URLSession) -> WorkerClient {
        WorkerClient(baseURL: baseURL, session: transport, credentialAuthority: authority,
                     dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(),
                     admitCredentialRejection: { _, _ in .stale })
    }
    private func api(_ authority: SessionCredentialAuthority, _ context: CredentialRequestContext, _ transport: URLSession) throws -> VoiceSessionAPIClient {
        try VoiceSessionAPIClient(workerClient: worker(authority, transport), credentialAuthority: authority,
                                  credentialContext: context, baseURL: baseURL, session: transport,
                                  dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider())
    }
    private func registry(_ authority: SessionCredentialAuthority, _ transport: URLSession, _ defaults: UserDefaults) -> VoiceSessionRegistry {
        VoiceSessionRegistry(defaults: defaults, credentialAuthority: authority,
                             currentUserIDProvider: { (try? authority.snapshot()).map { DerivedUserID.from($0.lease.rawUserID) } },
                             sessionAPIFactory: { try api(authority, $0, transport) })
    }
    private func realtime(_ authority: SessionCredentialAuthority, _ context: CredentialRequestContext,
                          _ transport: URLSession, client: FakeRealtimeClient, state: VoiceSessionState,
                          socket: VoiceOwnershipSocket) throws -> RealtimeVoiceSession {
        try RealtimeVoiceSession(coordinator: AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator()),
                                 keyFetcher: VoiceOwnershipDisabledKeyFetcher(), client: client, state: state,
                                 credentialAuthority: authority, credentialContext: context,
                                 sessionAPI: api(authority, context, transport), audioModePreflighted: false, scopedControlSocketFactory: { _, _, _ in socket })
    }
    nonisolated private func createReply() -> VoiceOwnershipURLProtocol.Response {
        .init(200, #"{"rishiSessionId":"voice-A","nonce":"nonce","clientSecret":"fixture-secret","capIntervals":1,"realtimeModel":"fixture"}"#)
    }

    @Test("Scoped constructors reject mismatched API context and deletion before transport")
    func constructorBinding() throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        defer { session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let context = CredentialRequestContext.normal(a.lease)
        let api = try api(authority, context, session)
        let other = CredentialRequestContext.normal(.init(installationID: UUID(), epoch: 0, rawUserID: "A"))
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try RealtimeVoiceSession(coordinator: AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator()),
                                     keyFetcher: VoiceOwnershipDisabledKeyFetcher(), client: FakeRealtimeClient(), state: VoiceSessionState(),
                                     credentialAuthority: authority, credentialContext: other, sessionAPI: api, audioModePreflighted: false,
                                     scopedControlSocketFactory: { _, ctx, _ in VoiceOwnershipSocket(authority, ctx) })
        }
        #expect(throws: CredentialAuthenticationFailure.accountChanged) {
            try ControlWebSocketClient(baseURL: baseURL, credentialAuthority: authority,
                                       credentialContext: .deletion(transactionID: UUID(), outgoingLease: a.lease),
                                       dataUseConsentProvider: AlwaysAllowWorkerDataUseConsentProvider(), rishiSessionId: "voice-A",
                                       urlSession: session, onTerminal: { _ in })
        }
        #expect(VoiceOwnershipURLProtocol.requests.isEmpty)
    }

    @Test("Control consent suspension cannot read a replacement lease", arguments: ["B", "A"])
    func controlStaleConsent(_ replacement: String) async throws {
        let gate = VoiceOwnershipGate()
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        defer { gate.open(); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let control = try ControlWebSocketClient(baseURL: baseURL, credentialAuthority: authority, credentialContext: .normal(a.lease),
                                                 dataUseConsentProvider: VoiceOwnershipConsent(gate), rishiSessionId: "voice-A",
                                                 urlSession: session, onTerminal: { _ in })
        let task = Task { try await control.buildControlRequest() }
        defer { task.cancel() }
        await gate.waitForEntry()
        let b = try install(replacement, in: authority)
        gate.open()
        await #expect(throws: CredentialAuthenticationFailure.accountChanged) { try await task.value }
        #expect(try authority.snapshot() == b)
        #expect(VoiceOwnershipURLProtocol.requests.isEmpty)
    }

    @Test("Control uses a rotated token only within its captured lease")
    func controlSameLeaseRotation() async throws {
        let gate = VoiceOwnershipGate()
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        defer { gate.open(); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let control = try ControlWebSocketClient(baseURL: baseURL, credentialAuthority: authority, credentialContext: .normal(a.lease),
                                                 dataUseConsentProvider: VoiceOwnershipConsent(gate), rishiSessionId: "voice-A",
                                                 urlSession: session, onTerminal: { _ in })
        let task = Task { try await control.buildControlRequest() }
        defer { task.cancel() }
        await gate.waitForEntry()
        let rotated = try authority.commitRefresh(accessToken: "fresh-A", refreshToken: "fresh-refresh-A", issuedAt: Date(), expected: a)
        gate.open()
        let request = try await task.value
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-A")
        #expect(!request.httpShouldHandleCookies)
        #expect(rotated.lease == a.lease)
        #expect(VoiceOwnershipURLProtocol.requests.isEmpty)
    }

    @Test("Disconnect wins a suspended control connect before socket construction")
    func controlDisconnectFence() async throws {
        let gate = VoiceOwnershipGate()
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = VoiceOwnershipWebSocketSession()
        defer { gate.open(); session.invalidateAndCancel() }
        let control = try ControlWebSocketClient(baseURL: baseURL, credentialAuthority: authority, credentialContext: .normal(a.lease),
                                                 dataUseConsentProvider: VoiceOwnershipConsent(gate), rishiSessionId: "voice-A",
                                                 urlSession: session, onTerminal: { _ in })
        let task = Task { await control.connect() }
        defer { task.cancel() }
        await gate.waitForEntry()
        await control.disconnect()
        gate.open()
        await task.value
        #expect(session.requests.isEmpty)
    }

    @Test("Account retirement wins a suspended control connect before socket resume")
    func controlAccountFence() async throws {
        let gate = VoiceOwnershipGate()
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = VoiceOwnershipWebSocketSession()
        defer { gate.open(); session.invalidateAndCancel() }
        let control = try ControlWebSocketClient(baseURL: baseURL, credentialAuthority: authority, credentialContext: .normal(a.lease),
                                                 dataUseConsentProvider: VoiceOwnershipConsent(gate), rishiSessionId: "voice-A",
                                                 urlSession: session, onTerminal: { _ in })
        let task = Task { await control.connect() }
        defer { task.cancel() }
        await gate.waitForEntry()
        let b = try install("B", in: authority)
        gate.open()
        await task.value
        #expect(session.requests.isEmpty)
        #expect(try authority.snapshot() == b)
        await control.disconnect()
    }

    @Test("A late created session never reaches RTC, registration, or control", arguments: ["B", "A"])
    func staleCreateTransport(_ replacement: String) async throws {
        let gate = VoiceOwnershipGate()
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        let client = FakeRealtimeClient()
        let socket = VoiceOwnershipSocket(authority, .normal(a.lease))
        let realtime = try realtime(authority, .normal(a.lease), session, client: client, state: VoiceSessionState(), socket: socket)
        VoiceOwnershipURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/end") == true { return .init(200, #"{"ok":true}"#) }
            await gate.pause()
            return createReply()
        }
        let task = Task { await realtime.start() }
        defer { task.cancel(); gate.open(); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        await gate.waitForEntry()
        let b = try install(replacement, in: authority)
        gate.open()
        #expect(await task.value == .cancelled)
        #expect(client.connectCalls.isEmpty)
        #expect(socket.connectCount == 0)
        #expect(VoiceOwnershipURLProtocol.requests.map { $0.url?.path } == ["/api/voice-sessions", "/api/voice-sessions/voice-A/end"])
        #expect(VoiceOwnershipURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" })
        #expect(try authority.snapshot() == b)
        #expect(await realtime.serverCreationReceipt == nil)
    }

    @Test("An incorrectly bound control factory fails closed before registration")
    func mismatchedSocketFactory() async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        defer { session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        VoiceOwnershipURLProtocol.setHandler { request in
            request.url?.path.hasSuffix("/end") == true ? .init(200, #"{"ok":true}"#) : createReply()
        }
        let client = FakeRealtimeClient()
        client.setProviderCallId("fixture-call")
        let wrongAuthority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let socket = VoiceOwnershipSocket(wrongAuthority, .normal(a.lease))
        let realtime = try realtime(authority, .normal(a.lease), session, client: client, state: VoiceSessionState(), socket: socket)
        #expect(await realtime.start() == .failed(.connect))
        #expect(socket.connectCount == 0)
        #expect(client.disconnectCalls == 1)
        #expect(VoiceOwnershipURLProtocol.requests.count == 1)
        let receipt = try #require(await realtime.serverCreationReceipt)
        try await receipt.endSpecificSession()
        _ = await realtime.end()
    }

    @Test("Passed-session late creation remains retryable after registry detached it", arguments: ["B", "A", "same-lease"])
    func detachedLateCreateRetry(_ replacement: String) async throws {
        let gate = VoiceOwnershipGate()
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        let name = "VoiceOwnership.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); gate.open(); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let registry = registry(authority, session, defaults)
        let client = FakeRealtimeClient()
        let socket = VoiceOwnershipSocket(authority, .normal(a.lease))
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let presenter = try VoiceSessionPresenter(
            coordinator: coordinator, workerClient: worker(authority, session), baseURL: baseURL,
            messageStore: InMemoryMessageStore(), conversationLookup: ConversationLookup(store: InMemoryConversationStore()),
            userIdProvider: { (try? authority.snapshot()).map { DerivedUserID.from($0.lease.rawUserID) } }, dirtyHook: VoiceOwnershipDirtyHook(),
            micGate: VoiceOwnershipMicGate(), clientFactory: { client }, credentialAuthority: authority,
            sessionAPIFactory: { try api(authority, $0, session) }, scopedControlSocketFactory: { _, _, _ in socket }, sessionRegistry: registry
        )
        VoiceOwnershipURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/end") == true { return .init(401) }
            await gate.pause()
            return createReply()
        }
        let task = Task { await presenter.start(bookId: nil) }
        defer { task.cancel() }
        await gate.waitForEntry()
        #expect(registry.activeSession != nil)
        await presenter.requestEnd()
        await registry.waitForServerEnd()
        #expect(registry.activeSession == nil)
        #expect(registry.state == .ended)
        let b = replacement == "same-lease" ? a : try install(replacement, in: authority)
        registry.recordServerSessionID("voice-B", owner: DerivedUserID.from(b.lease.rawUserID))
        let persistedB = try #require(defaults.data(forKey: VoiceSessionRegistry.persistedIDKey))
        #expect(await coordinator.requestVoiceActiveMode())
        gate.open()
        #expect(await task.value == .rejected)
        #expect(await coordinator.currentMode == .voice) // old A cleanup must not release B's subsequent claim
        await coordinator.releaseActiveMode(.voice)
        #expect(client.connectCalls.isEmpty)
        #expect(socket.connectCount == 0)
        let failedEnds = VoiceOwnershipURLProtocol.requests.filter { $0.url?.path.hasSuffix("/end") == true }
        #expect(failedEnds.count == 4) // one actor compensation plus the existing three-attempt registry delivery
        #expect(failedEnds.allSatisfy { $0.url?.path == "/api/voice-sessions/voice-A/end" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-A" && !$0.httpShouldHandleCookies })
        #expect(registry.persistedServerSessionID == "voice-B")
        #expect(defaults.data(forKey: VoiceSessionRegistry.persistedIDKey) == persistedB)
        #expect(try authority.snapshot() == b)
        VoiceOwnershipURLProtocol.setHandler { _ in .init(200, #"{"ok":true}"#) }
        #expect(await registry.retryPendingCreationReceipts())
        let retries = VoiceOwnershipURLProtocol.requests
        #expect(retries.count == 1)
        #expect(retries[0].url?.path == "/api/voice-sessions/voice-A/end")
        #expect(retries[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-A")
        #expect(registry.persistedServerSessionID == "voice-B")
        #expect(defaults.data(forKey: VoiceSessionRegistry.persistedIDKey) == persistedB)
        #expect(try authority.snapshot() == b)
        #expect(!presenter.isPresenting)
    }

    @Test("Registry rereads a receipt after local end and cannot clear a new owner's record")
    func registryEndReceiptReread() async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        let name = "VoiceOwnership.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let gate = VoiceOwnershipGate()
        defer { gate.open(); defaults.removePersistentDomain(forName: name); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        VoiceOwnershipURLProtocol.setHandler { request in request.url?.path.hasSuffix("/end") == true ? .init(200, #"{"ok":true}"#) : createReply() }
        let receipt = try await api(authority, .normal(a.lease), session).startSessionWithReceipt(language: nil, bookContext: nil)
        let fixture = VoiceOwnershipRegistrySession(receipt, gate)
        let registry = registry(authority, session, defaults)
        await registry.register(fixture)
        await registry.close()
        await gate.waitForEntry()
        let b = try install("B", in: authority)
        registry.recordServerSessionID("voice-B", owner: DerivedUserID.from(b.lease.rawUserID))
        gate.open()
        await registry.waitForServerEnd()
        #expect(registry.state == .ended)
        #expect(registry.persistedServerSessionID == "voice-B")
        let ends = VoiceOwnershipURLProtocol.requests.filter { $0.url?.path.hasSuffix("/end") == true }
        #expect(ends.count == 1)
        #expect(ends[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-A")
        #expect(try authority.snapshot() == b)
    }

    @Test("Explicit preflight transfer can end before start without releasing a later owner")
    func preflightTransferEndBeforeStart() async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        defer { session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        #expect(await coordinator.requestVoiceActiveMode())
        let realtime = try RealtimeVoiceSession(coordinator: coordinator, keyFetcher: VoiceOwnershipDisabledKeyFetcher(),
                                                client: FakeRealtimeClient(), state: VoiceSessionState(), credentialAuthority: authority,
                                                credentialContext: .normal(a.lease), sessionAPI: api(authority, .normal(a.lease), session),
                                                audioModePreflighted: true,
                                                scopedControlSocketFactory: { _, ctx, _ in VoiceOwnershipSocket(authority, ctx) })
        _ = await realtime.end()
        #expect(await coordinator.currentMode == .idle)
        _ = try install("B", in: authority)
        #expect(await coordinator.requestVoiceActiveMode())
        #expect(await realtime.start(preflighted: true) == .cancelled)
        #expect(await coordinator.currentMode == .voice)
        #expect(VoiceOwnershipURLProtocol.requests.isEmpty)
        await coordinator.releaseActiveMode(.voice)
    }

    @Test("Registry close wins a same-owner suspended resume without restoring live", arguments: ["getter", "resume"])
    func closeDuringResume(_ phase: String) async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        let name = "VoiceOwnership.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        let gate = VoiceOwnershipGate()
        let endGate = VoiceOwnershipGate()
        endGate.open()
        defer { gate.open(); endGate.open(); defaults.removePersistentDomain(forName: name); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        VoiceOwnershipURLProtocol.setHandler { request in
            request.url?.path.hasSuffix("/end") == true ? .init(200, #"{"ok":true}"#) : createReply()
        }
        let receipt = try await api(authority, .normal(a.lease), session).startSessionWithReceipt(language: nil, bookContext: nil)
        let fixture = VoiceOwnershipRegistrySession(receipt, endGate,
            leaseGate: phase == "getter" ? gate : nil, resumeGate: phase == "resume" ? gate : nil)
        let registry = registry(authority, session, defaults)
        await registry.register(fixture)
        registry.recordServerSessionID("voice-A", owner: DerivedUserID.from("A"))
        await registry.park()
        let resume = Task { await registry.resume() }
        defer { resume.cancel() }
        await gate.waitForEntry()
        await registry.close()
        await registry.waitForServerEnd()
        #expect(registry.state == .ended)
        #expect(registry.activeSession == nil)
        #expect(registry.persistedServerSessionID == nil)
        gate.open()
        await resume.value
        #expect(registry.state == .ended)
        #expect(registry.activeSession == nil)
        #expect(registry.parkedUntil == nil)
        #expect(registry.persistedServerSessionID == nil)
        #expect(await fixture.resumeCount == (phase == "getter" ? 0 : 1))
        #expect(await fixture.endCount == 1)
        #expect(await fixture.parkCount == 1)
        #expect(try authority.snapshot() == a)
        let ends = VoiceOwnershipURLProtocol.requests.filter { $0.url?.path.hasSuffix("/end") == true }
        #expect(ends.count == 1)
        #expect(ends[0].value(forHTTPHeaderField: "Authorization") == "Bearer access-A")
    }

    @Test("Consent End admits only its original current lease", arguments: ["current", "replacement", "ABA"])
    func capturedConsentEnd(_ transition: String) async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let original = try install("A", in: authority)
        let current: CredentialSnapshot
        switch transition {
        case "replacement": current = try install("B", in: authority)
        case "ABA":
            _ = try install("B", in: authority)
            current = try install("A", in: authority)
            #expect(current.lease.rawUserID == original.lease.rawUserID)
            #expect(current.lease != original.lease)
        default: current = original
        }
        let gate = VoiceOwnershipGate()
        let session = transport()
        let name = "VoiceOwnership.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { gate.open(); defaults.removePersistentDomain(forName: name); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let registry = registry(authority, session, defaults)
        let client = FakeRealtimeClient()
        let socket = VoiceOwnershipSocket(authority, .normal(current.lease))
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let presenter = try VoiceSessionPresenter(
            coordinator: coordinator, workerClient: worker(authority, session), baseURL: baseURL,
            messageStore: InMemoryMessageStore(), conversationLookup: ConversationLookup(store: InMemoryConversationStore()),
            userIdProvider: { (try? authority.snapshot()).map { DerivedUserID.from($0.lease.rawUserID) } }, dirtyHook: VoiceOwnershipDirtyHook(),
            micGate: VoiceOwnershipMicGate(), clientFactory: { client }, credentialAuthority: authority,
            sessionAPIFactory: { try api(authority, $0, session) }, scopedControlSocketFactory: { _, context, _ in
                if case .normal(let lease) = context, lease == current.lease { return socket }
                return VoiceOwnershipSocket(authority, context)
            }, sessionRegistry: registry
        )
        VoiceOwnershipURLProtocol.setHandler { request in
            if request.url?.path.hasSuffix("/end") == true { return .init(200, #"{"ok":true}"#) }
            await gate.pause()
            return createReply()
        }
        let start = Task { await presenter.start(bookId: nil) }
        defer { start.cancel() }
        await gate.waitForEntry()
        let active = try #require(presenter.session)
        #expect(presenter.isPresenting)
        #expect(registry.activeSession === active)
        #expect(await coordinator.currentMode == .voice)
        #expect(VoiceOwnershipURLProtocol.requests.count == 1)

        if transition != "current" {
            await #expect(throws: CredentialAuthenticationFailure.accountChanged) {
                try await presenter.requestEnd(credentialContext: .normal(original.lease))
            }
            // This is a real replacement start suspended in its admitted create,
            // rather than an empty presenter that cannot demonstrate teardown.
            #expect(presenter.session === active)
            #expect(presenter.isPresenting)
            #expect(registry.activeSession === active)
            #expect(registry.state == .live)
            #expect(await coordinator.currentMode == .voice)
            #expect(client.disconnectCalls == 0)
            #expect(VoiceOwnershipURLProtocol.requests.count == 1)
            #expect(try authority.snapshot() == current)
        }

        try await presenter.requestEnd(credentialContext: .normal(current.lease))
        await registry.waitForServerEnd()
        #expect(presenter.session == nil)
        #expect(!presenter.isPresenting)
        #expect(registry.activeSession == nil)
        #expect(registry.state == .ended)
        #expect(await coordinator.currentMode == .idle)
        gate.open()
        #expect(await start.value == .rejected)
        await registry.waitForServerEnd()
        #expect(client.connectCalls.isEmpty)
        #expect(socket.connectCount == 0)
        #expect(VoiceOwnershipURLProtocol.requests.map { $0.url?.path } == ["/api/voice-sessions", "/api/voice-sessions/voice-A/end"])
        #expect(VoiceOwnershipURLProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-\(current.lease.rawUserID)" && !$0.httpShouldHandleCookies
        })
        #expect(registry.persistedServerSessionID == nil)
        #expect(try authority.snapshot() == current)

        if transition == "current" {
            // Complete the same owner's full teardown first, then reuse the
            // actual Presenter for B. A completed A flight must not swallow B End.
            let next = try install("B", in: authority)
            let nextGate = VoiceOwnershipGate()
            defer { nextGate.open() }
            VoiceOwnershipURLProtocol.setHandler { request in
                if request.url?.path.hasSuffix("/end") == true { return .init(200, #"{"ok":true}"#) }
                await nextGate.pause()
                return createReply()
            }
            let nextStart = Task { await presenter.start(bookId: nil) }
            defer { nextStart.cancel() }
            await nextGate.waitForEntry()
            #expect(presenter.isPresenting)
            #expect(registry.activeSession != nil)
            try await presenter.requestEnd(credentialContext: .normal(next.lease))
            await registry.waitForServerEnd()
            #expect(!presenter.isPresenting)
            #expect(presenter.session == nil)
            #expect(registry.activeSession == nil)
            #expect(registry.state == .ended)
            #expect(await coordinator.currentMode == .idle)
            nextGate.open()
            #expect(await nextStart.value == .rejected)
            await registry.waitForServerEnd()
            #expect(VoiceOwnershipURLProtocol.requests.map { $0.url?.path } == ["/api/voice-sessions", "/api/voice-sessions/voice-A/end"])
            #expect(VoiceOwnershipURLProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer access-B" && !$0.httpShouldHandleCookies })
            #expect(client.connectCalls.isEmpty)
            #expect(registry.persistedServerSessionID == nil)
            #expect(try authority.snapshot() == next)
        }
    }

    @Test("End joins a suspended audio claim and late finalization cannot reacquire ownership")
    func pendingAudioClaimEnd() async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        let claimGate = VoiceOwnershipGate()
        let endGate = VoiceOwnershipGate()
        defer { claimGate.open(); endGate.open(); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        await coordinator.requestActiveMode(.tts)
        await coordinator.registerPreemption(for: .tts) { await claimGate.pause() }
        let client = VoiceOwnershipEndNotifyingClient(endGate)
        let realtime = try RealtimeVoiceSession(coordinator: coordinator, keyFetcher: VoiceOwnershipDisabledKeyFetcher(),
                                                client: client, state: VoiceSessionState(), credentialAuthority: authority,
                                                credentialContext: .normal(a.lease), sessionAPI: api(authority, .normal(a.lease), session),
                                                audioModePreflighted: false,
                                                scopedControlSocketFactory: { _, ctx, _ in VoiceOwnershipSocket(authority, ctx) })
        let start = Task { await realtime.start() }
        defer { start.cancel() }
        await claimGate.waitForEntry()
        let end = Task { await realtime.end() }
        defer { end.cancel() }
        // The client's normal cancel-current-response callback proves End entered,
        // while the native audio claim is still suspended in TTS preemption.
        await endGate.waitForEntry()
        claimGate.open()
        _ = await end.value
        #expect(await start.value == .cancelled)
        #expect(await coordinator.currentMode == .idle)
        #expect(client.base.connectCalls.isEmpty)
        #expect(VoiceOwnershipURLProtocol.requests.isEmpty)
        _ = try install("B", in: authority)
        #expect(await coordinator.requestVoiceActiveMode())
        _ = await realtime.end()
        #expect(await coordinator.currentMode == .voice)
        await coordinator.releaseActiveMode(.voice)
    }

    @Test("Crash recovery stores ID/owner only and admits a fresh context only for that owner")
    func persistedOwnerRecovery() async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let session = transport()
        let name = "VoiceOwnership.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); session.invalidateAndCancel(); VoiceOwnershipURLProtocol.reset() }
        let registry = registry(authority, session, defaults)
        registry.recordServerSessionID("voice-A", owner: DerivedUserID.from(a.lease.rawUserID))
        let data = try #require(defaults.data(forKey: VoiceSessionRegistry.persistedIDKey))
        let stored = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(stored.keys) == Set(["id", "userID"]))
        #expect(stored["id"] as? String == "voice-A")
        #expect(stored["userID"] as? String == DerivedUserID.from("A").uuidString)
        let b = try install("B", in: authority)
        await registry.recoverPersistedSession()
        #expect(VoiceOwnershipURLProtocol.requests.isEmpty)
        #expect(defaults.data(forKey: VoiceSessionRegistry.persistedIDKey) == data)
        #expect(try authority.snapshot() == b)
        let nextA = try install("A", in: authority)
        let freshA = try authority.commitRefresh(accessToken: "recovered-A", refreshToken: "recovered-refresh-A", issuedAt: Date(), expected: nextA)
        VoiceOwnershipURLProtocol.setHandler { _ in .init(200, #"{"ok":true}"#) }
        // A new registry models a fresh process: no in-memory receipt was persisted.
        let restored = self.registry(authority, session, defaults)
        await restored.recoverPersistedSession()
        #expect(VoiceOwnershipURLProtocol.requests.count == 1)
        #expect(VoiceOwnershipURLProtocol.requests[0].url?.path == "/api/voice-sessions/voice-A/end")
        #expect(VoiceOwnershipURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer recovered-A")
        #expect(defaults.data(forKey: VoiceSessionRegistry.persistedIDKey) == nil)
        #expect(try authority.snapshot() == freshA)
    }

    @Test("Reconnect rechecks ending/account ownership after a suspended key fetch", arguments: [false, true])
    func reconnectFinalGuard(_ accountChanged: Bool) async throws {
        let authority = SessionCredentialAuthority(persistence: VoiceOwnershipMemoryPersistence())
        let a = try install("A", in: authority)
        let gate = VoiceOwnershipGate()
        let finalGuard = VoiceOwnershipGate()
        let ending = Mutex(false)
        let client = FakeRealtimeClient()
        let controller = ReconnectController(client: client, keyFetcher: VoiceOwnershipKeyFetcher(gate), backoff: { _ in .zero },
                                             maxReconnects: 1, disconnectConfirmations: 0, confirmationInterval: .zero, observationGracePeriod: .zero,
                                             callbacks: .init(isEnding: {
                                                 let rejected = ending.withLock { $0 } || (try? authority.snapshot(for: .normal(a.lease))) == nil
                                                 if rejected { finalGuard.open() }
                                                 return rejected
                                             }, onReconnecting: { _ in }, onReconnected: { _ in Issue.record("Unexpected reconnect") }, onExhausted: { Issue.record("Unexpected exhaustion") }))
        defer { gate.open(); finalGuard.open() }
        await controller.startStatusObservation()
        await gate.waitForEntry()
        if accountChanged { _ = try install("B", in: authority) } else { ending.withLock { $0 = true } }
        gate.open()
        await finalGuard.waitForEntry()
        await controller.cancel()
        #expect(client.connectCalls.isEmpty)
    }
}

private final class VoiceOwnershipEndNotifyingClient: RealtimeClientAPI, Sendable {
    let base = FakeRealtimeClient()
    private let gate: VoiceOwnershipGate
    init(_ gate: VoiceOwnershipGate) { self.gate = gate }
    func connect(ephemeralKey: String, bookContext: BookContextSnapshot?, language: String?, deferMicCapture: Bool) async throws {
        try await base.connect(ephemeralKey: ephemeralKey, bookContext: bookContext, language: language, deferMicCapture: deferMicCapture)
    }
    func setMicCaptureEnabled(_ enabled: Bool) async { await base.setMicCaptureEnabled(enabled) }
    func cancelCurrentResponse() async { gate.open(); await base.cancelCurrentResponse() }
    func disconnect() async { await base.disconnect() }
    func currentStatus() async -> RealtimeConnectionStatus { await base.currentStatus() }
    var providerCallId: String? { get async { base.providerCallId } }
    func errorStream() -> AsyncStream<RealtimeClientError> { base.errorStream() }
    func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> { base.transcriptStream() }
    func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> { base.toolCallStream() }
    func sendToolResult(callId: String, payload: String) async throws { try await base.sendToolResult(callId: callId, payload: payload) }
}

private struct VoiceOwnershipDisabledKeyFetcher: EphemeralKeyFetching {
    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        Issue.record("Scoped voice must never fetch an unscoped key")
        throw CredentialAuthenticationFailure.accountChanged
    }
}
private struct VoiceOwnershipMicGate: MicPermissionGate {
    func request() async -> MicPermissionDecision { .granted }
}
private struct VoiceOwnershipDirtyHook: VoiceTranscriptDirtyHook {
    func conversationDidUpdate(_ id: ConversationID) async {}
    func messageDidUpdate(_ id: MessageID) async {}
}
private struct VoiceOwnershipConsent: WorkerDataUseConsentProvider {
    let gate: VoiceOwnershipGate
    init(_ gate: VoiceOwnershipGate) { self.gate = gate }
    func hasCurrentDataUseConsent() async -> Bool { await gate.pause(); return true }
}
private struct VoiceOwnershipKeyFetcher: EphemeralKeyFetching {
    let gate: VoiceOwnershipGate
    init(_ gate: VoiceOwnershipGate) { self.gate = gate }
    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        await gate.pause()
        return .init(secret: "fixture-key", sessionId: "fixture-session")
    }
}
private actor VoiceOwnershipRegistrySession: VoiceSessionRegistrySession {
    private let receipt: VoiceSessionCreationReceipt
    private let gate: VoiceOwnershipGate
    private let leaseGate: VoiceOwnershipGate?
    private let resumeGate: VoiceOwnershipGate?
    private var leaseReads = 0
    private(set) var parkCount = 0
    private(set) var resumeCount = 0
    private(set) var endCount = 0
    private var delivered = false
    init(_ receipt: VoiceSessionCreationReceipt, _ gate: VoiceOwnershipGate,
         leaseGate: VoiceOwnershipGate? = nil, resumeGate: VoiceOwnershipGate? = nil) {
        self.receipt = receipt; self.gate = gate; self.leaseGate = leaseGate; self.resumeGate = resumeGate
    }
    var credentialLease: CredentialLease? {
        get async {
            leaseReads += 1
            if leaseReads == 2 { await leaseGate?.pause() }
            return receipt.lease
        }
    }
    var serverCreationReceipt: VoiceSessionCreationReceipt? { delivered ? receipt : nil }
    var rishiSessionId: String? { delivered ? receipt.started.rishiSessionId : nil }
    func parkForBackground() { parkCount += 1 }
    func resumeFromBackground() async { resumeCount += 1; await resumeGate?.pause() }
    func end() async -> String? { endCount += 1; await gate.pause(); delivered = true; return receipt.started.rishiSessionId }
}
private final class VoiceOwnershipSocket: CredentialBoundControlSocketConnecting, Sendable {
    let authority: SessionCredentialAuthority
    let context: CredentialRequestContext
    let messages: AsyncStream<ControlMessage> = AsyncStream { $0.finish() }
    private let count = Mutex(0)
    init(_ authority: SessionCredentialAuthority, _ context: CredentialRequestContext) { self.authority = authority; self.context = context }
    var connectCount: Int { count.withLock { $0 } }
    func isBound(to authority: SessionCredentialAuthority, context: CredentialRequestContext) -> Bool {
        guard case .normal(let actual) = self.context, case .normal(let expected) = context else { return false }
        return self.authority === authority && actual == expected
    }
    func connect() async { count.withLock { $0 += 1 } }
    func reconnect() async {}
    func disconnect() async {}
    func sendClientAck() async {}
    func sendClientActivity() async {}
}
/// Any accidentally constructed native task is canceled before delivery to the caller.
/// Thus a failed assertion cannot open a remote socket, even if production resumes it.
private final class VoiceOwnershipWebSocketSession: URLSession, @unchecked Sendable {
    private let dormantSession = URLSession(configuration: .ephemeral)
    private let requestStorage = Mutex<[URLRequest]>([])
    var requests: [URLRequest] { requestStorage.withLock { $0 } }
    override func webSocketTask(with request: URLRequest) -> URLSessionWebSocketTask {
        requestStorage.withLock { $0.append(request) }
        let task = dormantSession.webSocketTask(with: request)
        task.cancel(with: .normalClosure, reason: nil)
        return task
    }
    override func invalidateAndCancel() { dormantSession.invalidateAndCancel() }
}

private final class VoiceOwnershipMemoryPersistence: SessionCredentialPersistence, Sendable {
    private struct State { var data: Data?; var reads = 0 }
    private let state = Mutex(State())
    var readCount: Int { state.withLock { $0.reads } }
    func readCanonical() -> Data? { state.withLock { $0.reads += 1; return $0.data } }
    func writeCanonical(_ data: Data) { state.withLock { $0.data = data } }
    func readLegacy() -> LegacyCredentials { .init(accessToken: nil, refreshToken: nil, userID: nil) }
    func removeLegacy() {}
}

private final class VoiceOwnershipGate: Sendable {
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

private final class VoiceOwnershipURLProtocol: URLProtocol, @unchecked Sendable {
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
