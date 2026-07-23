//


//







//

import Testing
import Foundation
import RishiCore
import RishiAudio
import RishiCore
import RishiChat
import RishiVoice
@testable import rishi

@MainActor
@Suite("VoiceSessionPresenter single-session invariant", .serialized)
struct VoiceSessionPresenterSingleSessionTests {

    final class BlockingConversationStore: ConversationStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var blocking: CheckedContinuation<Void, Error>?
        private var entered: CheckedContinuation<Void, Never>?
        private var cancelled = false

        var calls: Int { lock.withLock { _calls } }

   
        func waitUntilEntered() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let alreadyEntered: Bool = lock.withLock {
                    if _calls > 0 { return true }
                    entered = c
                    return false
                }
                if alreadyEntered { c.resume() }
            }
        }

        func conversations(for userId: UserID) async throws -> [Conversation] {
            let enteredCont: CheckedContinuation<Void, Never>? = lock.withLock {
                _calls += 1
                let e = entered
                entered = nil
                return e
            }
            enteredCont?.resume()

            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    let resumeNow: Bool = lock.withLock {
                        if cancelled { return true }
                        blocking = c
                        return false
                    }
                    if resumeNow { c.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let c: CheckedContinuation<Void, Error>? = lock.withLock {
                    cancelled = true
                    let b = blocking
                    blocking = nil
                    return b
                }
                c?.resume(throwing: CancellationError())
            }
            return []
        }

        func conversation(_ id: ConversationID) async throws -> Conversation? { nil }
        func upsert(_ conversation: Conversation) async throws {}
        func delete(_ id: ConversationID) async throws {}
    }

    private struct StubTokenProvider: TokenProvider {
        func token() async -> String? { nil }
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

    private struct InstantKeyFetcher: EphemeralKeyFetching {
        func fetch(
            language: String?,
            bookContext: BookContextSnapshot?
        ) async throws -> EphemeralKey {
            EphemeralKey(secret: "secret", sessionId: "session")
        }
    }

    private final class RecordingRealtimeClient: RealtimeClientAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var _connectCount = 0
        private var status: RealtimeConnectionStatus = .disconnected

        var connectCount: Int { lock.withLock { _connectCount } }

        func connect(
            ephemeralKey: String,
            bookContext: BookContextSnapshot?,
            language: String?,
            deferMicCapture: Bool
        ) async throws {
            lock.withLock {
                _connectCount += 1
                status = .connected
            }
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
        func disconnect() async {
            lock.withLock { status = .disconnected }
        }
        func currentStatus() async -> RealtimeConnectionStatus {
            lock.withLock { status }
        }
        var providerCallId: String? { nil }
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

    private func makePresenter(store: BlockingConversationStore) -> VoiceSessionPresenter {
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
            conversationLookup: ConversationLookup(store: store),
            userIdProvider: { userId },
            dirtyHook: StubDirtyHook(),
            clientFactory: { RecordingRealtimeClient() },
            keyFetcherFactory: { InstantKeyFetcher() },
            sessionCoordinatorFactory: { nil }
        )
    }

    @Test("a second start() while the first is mid-lookup is a no-op — one session")
    func concurrentStartCreatesOneSession() async {
        let store = BlockingConversationStore()
        let presenter = makePresenter(store: store)

        
        let taskA = Task { await presenter.start(bookId: UUID()) }
        await store.waitUntilEntered()

        
        #expect(presenter.isPresenting == true)
        #expect(store.calls == 1)

        
        
        
        await presenter.start(bookId: UUID())
        #expect(store.calls == 1)

        
        taskA.cancel()
        _ = await taskA.value
    }

    @Test("voice transport connects before conversation lookup finishes")
    func transportStartsWhileConversationLookupIsBlocked() async {
        let store = BlockingConversationStore()
        let client = RecordingRealtimeClient()
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let worker = WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StubTokenProvider()
        )
        let userId: UserID = UUID()
        let presenter = VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: worker,
            messageStore: StubMessageStore(),
            conversationLookup: ConversationLookup(store: store),
            userIdProvider: { userId },
            dirtyHook: StubDirtyHook(),
            clientFactory: { client },
            keyFetcherFactory: { InstantKeyFetcher() },
            sessionCoordinatorFactory: { nil }
        )

        let startTask = Task { await presenter.start(bookId: UUID()) }
        await store.waitUntilEntered()

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, client.connectCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.connectCount == 1)
        #expect(presenter.state.status == .live)

        startTask.cancel()
        _ = await startTask.value
    }
}
