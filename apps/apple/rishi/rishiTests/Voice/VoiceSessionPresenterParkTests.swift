import Foundation
import Testing




@testable import rishi

@MainActor
@Suite("VoiceSessionPresenter session parking", .serialized)
struct VoiceSessionPresenterParkTests {

    private struct GrantedMicGate: MicPermissionGate {
        func request() async -> MicPermissionDecision { .granted }
    }

    private struct EmptyConversationStore: ConversationStore, @unchecked Sendable {
        func conversations(for userId: UserID) async throws -> [Conversation] { [] }
        func conversation(_ id: ConversationID) async throws -> Conversation? { nil }
        func upsert(_ conversation: Conversation) async throws {}
        func delete(_ id: ConversationID) async throws {}
    }

    private struct StubMessageStore: MessageStore {
        func messages(for conversationId: ConversationID) async throws -> [Message] { [] }
        func message(_ id: MessageID) async throws -> Message? { nil }
        func upsert(_ message: Message) async throws {}
        func delete(_ id: MessageID) async throws {}
    }

    private struct StubDirtyHook: VoiceTranscriptDirtyHook {
        func conversationDidUpdate(_ id: ConversationID) async {}
        func messageDidUpdate(_ id: MessageID) async {}
    }

    private struct StubTokenProvider: TokenProvider {
        func token() async -> String? { nil }
    }

    private struct ParkTestKeyFetcher: EphemeralKeyFetching {
        func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
            EphemeralKey(secret: "k", sessionId: "s")
        }
    }

    private final class ParkTestRealtimeClient: RealtimeClientAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var status: RealtimeConnectionStatus = .connected
        private var connectCount = 0

        var connectCountSnapshot: Int { lock.withLock { connectCount } }

        func connect(
            ephemeralKey: String,
            bookContext: BookContextSnapshot?,
            language: String?,
            deferMicCapture: Bool
        ) async throws {
            lock.withLock { connectCount += 1 }
        }

        func setMicCaptureEnabled(_ enabled: Bool) async {}
        func setAssistantOutputEnabled(_ enabled: Bool) async {}
        func cancelCurrentResponse() async {}
        func injectBufferedInputAudio(_ pcm16le24kMono: Data) async throws -> HandoffAcceptance {
            .accepted(path: .path0A)
        }
        func injectBufferedInputText(_ text: String) async throws -> HandoffAcceptance {
            .accepted(path: .path0C)
        }

        func disconnect() async {}

        func currentStatus() async -> RealtimeConnectionStatus {
            lock.withLock { status }
        }

        var providerCallId: String? { get async { "call-test" } }

        func errorStream() -> AsyncStream<RealtimeClientError> {
            AsyncStream { $0.finish() }
        }

        func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> {
            AsyncStream { $0.finish() }
        }

        func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> {
            AsyncStream { $0.finish() }
        }

        func sendToolResult(callId: String, payload: String) async throws {}
    }

    private struct NoOpSessionCoordinator: VoiceSessionCoordinating {
        func startSession(
            language: String?,
            bookContext: BookContextSnapshot?
        ) async throws -> StartedVoiceSession {
            StartedVoiceSession(
                rishiSessionId: "rishi-test",
                nonce: "nonce",
                clientSecret: "secret",
                capIntervals: 10,
                realtimeModel: "gpt-realtime-2.1-mini"
            )
        }

        func registerCall(rishiSessionId: String, callId: String, nonce: String) async throws {}
        func endSession(rishiSessionId: String) async throws {}
    }

    private actor EndGate {
        private(set) var startCount = 0
        private(set) var endCount = 0
        private var endEntered = false
        private var releaseEnd = false

        func recordStart() { startCount += 1 }

        func enterEnd() {
            endCount += 1
            endEntered = true
        }

        func waitForEnd() async {
            while !endEntered {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }

        func release() { releaseEnd = true }

        func waitForRelease() async {
            while !releaseEnd {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private struct DelayedEndSessionCoordinator: VoiceSessionCoordinating {
        let gate: EndGate

        func startSession(
            language: String?,
            bookContext: BookContextSnapshot?
        ) async throws -> StartedVoiceSession {
            await gate.recordStart()
            return StartedVoiceSession(
                rishiSessionId: "rishi-test",
                nonce: "nonce",
                clientSecret: "secret",
                capIntervals: 10,
                realtimeModel: "gpt-realtime-2.1-mini"
            )
        }

        func registerCall(rishiSessionId: String, callId: String, nonce: String) async throws {}

        func endSession(rishiSessionId: String) async throws {
            await gate.enterEnd()
            await gate.waitForRelease()
        }
    }

    private struct NoOpControlSocket: ControlSocketConnecting {
        nonisolated let messages: AsyncStream<ControlMessage> = AsyncStream { $0.finish() }

        func connect() async {}
        func reconnect() async {}
        func disconnect() async {}
        func sendClientActivity() async {}
        func sendClientAck() async {}
    }

    private final class TerminalCallbackBox: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable (ControlTerminalSignal) async -> Void)?

        func set(_ callback: @escaping @Sendable (ControlTerminalSignal) async -> Void) {
            lock.withLock { self.callback = callback }
        }

        func waitForCallback() async -> Bool {
            for _ in 0 ..< 100 {
                if lock.withLock({ callback != nil }) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }

        func fire(_ signal: ControlTerminalSignal) async {
            let callback = lock.withLock { self.callback }
            await callback?(signal)
        }
    }

    private func makePresenter(
        client: ParkTestRealtimeClient,
        terminalCallback: TerminalCallbackBox? = nil
    ) -> VoiceSessionPresenter {
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let worker = WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StubTokenProvider()
        )
        let userId: UserID = UUID()
        return VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: worker,
            messageStore: StubMessageStore(),
            conversationLookup: ConversationLookup(store: EmptyConversationStore()),
            userIdProvider: { userId },
            dirtyHook: StubDirtyHook(),
            micGate: GrantedMicGate(),
            clientFactory: { client },
            keyFetcherFactory: { ParkTestKeyFetcher() },
            sessionCoordinatorFactory: { NoOpSessionCoordinator() },
            controlSocketFactory: { _, callback in
                terminalCallback?.set(callback)
                return NoOpControlSocket()
            }
        )
    }

    private func makePresenter(
        client: ParkTestRealtimeClient,
        sessionCoordinator: any VoiceSessionCoordinating,
        terminalCallback: TerminalCallbackBox? = nil
    ) -> VoiceSessionPresenter {
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let worker = WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StubTokenProvider()
        )
        let userId: UserID = UUID()
        return VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: worker,
            messageStore: StubMessageStore(),
            conversationLookup: ConversationLookup(store: EmptyConversationStore()),
            userIdProvider: { userId },
            dirtyHook: StubDirtyHook(),
            micGate: GrantedMicGate(),
            clientFactory: { client },
            keyFetcherFactory: { ParkTestKeyFetcher() },
            sessionCoordinatorFactory: { sessionCoordinator },
            controlSocketFactory: { _, callback in
                terminalCallback?.set(callback)
                return NoOpControlSocket()
            }
        )
    }

    @Test("parkSession hides chrome but keeps the live session for resume")
    func parkThenResumeReusesSession() async {
        let client = ParkTestRealtimeClient()
        let presenter = makePresenter(client: client)

        await presenter.start(bookId: UUID())
        #expect(presenter.isPresenting == true)
        #expect(presenter.getSession() != nil)
        let connectsAfterStart = client.connectCountSnapshot

        await presenter.parkSession()
        #expect(presenter.isPresenting == false)
        #expect(presenter.getSession() != nil)

        await presenter.start(bookId: UUID())
        #expect(presenter.isPresenting == true)
        #expect(presenter.getSession() != nil)
        #expect(client.connectCountSnapshot == connectsAfterStart)
        #expect(presenter.state.status == .live)
    }

    @Test("dismissVoiceChrome parks for quick reopen")
    func dismissVoiceChromeParksSession() async {
        let client = ParkTestRealtimeClient()
        let presenter = makePresenter(client: client)

        await presenter.start(bookId: UUID())
        await presenter.dismissVoiceChrome()
        #expect(presenter.isPresenting == false)
        #expect(presenter.getSession() != nil)

        await presenter.start(bookId: UUID())
        #expect(presenter.isPresenting == true)
        #expect(client.connectCountSnapshot == 1)
    }

    @Test("requestEnd clears a parked session")
    func requestEndClearsParkedSession() async {
        let client = ParkTestRealtimeClient()
        let presenter = makePresenter(client: client)

        await presenter.start(bookId: UUID())
        await presenter.parkSession()
        #expect(presenter.getSession() != nil)

        await presenter.requestEnd()
        #expect(presenter.getSession() == nil)
        #expect(presenter.isPresenting == false)
    }

    @Test("terminal allowance failure closes voice chrome and prepares upgrade alert")
    func terminalAllowanceFailureClosesChromeAndPreparesUpgradeAlert() async {
        let terminalCallback = TerminalCallbackBox()
        let presenter = makePresenter(
            client: ParkTestRealtimeClient(),
            terminalCallback: terminalCallback
        )

        await presenter.start(bookId: UUID())
        #expect(await terminalCallback.waitForCallback())
        await terminalCallback.fire(
            ControlTerminalSignal(
                rishiSessionId: "rishi-test",
                reason: .planVoiceAllowanceExhausted
            )
        )

        #expect(presenter.isPresenting == false)
        #expect(presenter.pendingFailure?.primaryAction == .upgrade)
        #expect(presenter.sessionRegistry.activeSession == nil)
    }

    @Test("terminal trial-credit failure closes voice chrome and prepares upgrade alert")
    func terminalTrialCreditFailureClosesChromeAndPreparesUpgradeAlert() async {
        let terminalCallback = TerminalCallbackBox()
        let presenter = makePresenter(
            client: ParkTestRealtimeClient(),
            terminalCallback: terminalCallback
        )

        await presenter.start(bookId: UUID())
        #expect(await terminalCallback.waitForCallback())
        await terminalCallback.fire(
            ControlTerminalSignal(
                rishiSessionId: "rishi-test",
                reason: .trialCreditsExhausted
            )
        )

        #expect(presenter.isPresenting == false)
        #expect(presenter.pendingFailure?.primaryAction == .upgrade)
    }

    @Test("terminal callback arriving after End does not reopen failure UI")
    func terminalCallbackAfterEndIsIgnored() async {
        let terminalCallback = TerminalCallbackBox()
        let presenter = makePresenter(
            client: ParkTestRealtimeClient(),
            terminalCallback: terminalCallback
        )

        await presenter.start(bookId: UUID())
        #expect(await terminalCallback.waitForCallback())
        await presenter.requestEnd()
        await terminalCallback.fire(
            ControlTerminalSignal(
                rishiSessionId: "rishi-test",
                reason: .trialCreditsExhausted
            )
        )

        #expect(presenter.isPresenting == false)
        #expect(presenter.failure == nil)
        #expect(presenter.pendingFailure == nil)
    }

    @Test("starting after optimistic End waits for one ledger delivery")
    func startWaitsForPendingEndDelivery() async {
        let client = ParkTestRealtimeClient()
        let gate = EndGate()
        let sessionCoordinator = DelayedEndSessionCoordinator(gate: gate)
        let presenter = makePresenter(client: client, sessionCoordinator: sessionCoordinator)

        await presenter.start(bookId: UUID())
        await presenter.requestEnd()
        await gate.waitForEnd()

        let nextStart = Task { @MainActor in
            await presenter.start(bookId: UUID())
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await gate.startCount == 1)

        await gate.release()
        await nextStart.value

        #expect(await gate.endCount == 1)
        #expect(await gate.startCount == 2)
        #expect(presenter.state.status == .live)
    }
}
