//


//




//






//

import Testing
import Foundation





@testable import rishi

@MainActor
@Suite("VoiceSessionPresenter failure alert", .serialized)
struct VoiceSessionPresenterFailureAlertTests {

    @Test("normal startup does not force a remote stale-session probe")
    func staleCleanupRequiresLocalSessionEvidence() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("rishi/Voice/VoiceSessionPresenter.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("guard let rishiSessionId = staleRishiSessionId else"))
        #expect(source.contains("resolveServerAlreadyActiveConflict()"))
    }

    private struct DeniedMicGate: MicPermissionGate {
        func request() async -> MicPermissionDecision { .denied }
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

    private struct StubTokenProvider: TokenProvider {
        func token() async -> String? { nil }
    }

    private struct StubDirtyHook: VoiceTranscriptDirtyHook {
        func conversationDidUpdate(_ id: ConversationID) async {}
        func messageDidUpdate(_ id: MessageID) async {}
    }

    private final class InvocationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _clientFactoryCalls = 0
        private var _sessionCoordinatorFactoryCalls = 0

        var clientFactoryCalls: Int { lock.withLock { _clientFactoryCalls } }
        var sessionCoordinatorFactoryCalls: Int { lock.withLock { _sessionCoordinatorFactoryCalls } }

        func recordClientFactoryCall() { lock.withLock { _clientFactoryCalls += 1 } }
        func recordSessionCoordinatorFactoryCall() { lock.withLock { _sessionCoordinatorFactoryCalls += 1 } }
    }

    private func makePresenter() -> VoiceSessionPresenter {
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
            micGate: DeniedMicGate(),
//            clientFactory: { UITestFakeRealtimeClient() },
//            keyFetcherFactory: { UITestFakeEphemeralKeyFetcher() }
        )
    }

    @Test("a startup failure dismisses the cover and surfaces an alert")
    func micDenied_dismissesCoverAndSurfacesFailure() async {
        let presenter = makePresenter()
        await presenter.start(bookId: UUID())

        #expect(presenter.isPresenting == false)
        #expect(presenter.pendingFailure != nil || presenter.failure != nil)
    }

    @Test("missing consent surfaces a consent action instead of a generic retry")
    func missingConsent_surfacesConsentAction() async {
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let worker = WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StubTokenProvider()
        )
        let presenter = VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: worker,
            dataUseConsentProvider: NoWorkerDataUseConsentProvider(),
            messageStore: StubMessageStore(),
            conversationLookup: ConversationLookup(store: EmptyConversationStore()),
            userIdProvider: { UUID() },
            dirtyHook: StubDirtyHook(),
            micGate: DeniedMicGate()
        )

        await presenter.start(bookId: UUID())

        #expect(presenter.failure?.primaryAction == .requestDataUseConsent)
    }

    @Test("a repeated startup failure never strands the voice cover")
    func repeatedMicDenied_doesNotStrandCover() async {
        let presenter = makePresenter()

        
        await presenter.start(bookId: UUID())
        #expect(presenter.isPresenting == false)

        
        
        
        await presenter.start(bookId: UUID())
        #expect(presenter.isPresenting == false)
    }

    @Test("mic denial happens before realtime client or server session construction")
    func micDenied_precedesClientAndSessionWork() async {
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let worker = WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StubTokenProvider()
        )
        let userId: UserID = UUID()
        let calls = InvocationCounter()
        let presenter = VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: worker,
            messageStore: StubMessageStore(),
            conversationLookup: ConversationLookup(store: EmptyConversationStore()),
            userIdProvider: { userId },
            dirtyHook: StubDirtyHook(),
            micGate: DeniedMicGate(),
            clientFactory: {
                calls.recordClientFactoryCall()
                return FakeRealtimeClient()
            },
            sessionCoordinatorFactory: {
                calls.recordSessionCoordinatorFactoryCall()
                return nil
            }
        )

        await presenter.start(bookId: UUID())

        #expect(presenter.state.status == .failed(reason: .micDenied))
        #expect(calls.clientFactoryCalls == 0)
        #expect(calls.sessionCoordinatorFactoryCalls == 0)
        #expect(await coordinator.currentMode == .idle)
    }
}
