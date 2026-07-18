import Testing
import Foundation
@testable import rishi
import RishiAudio
import RishiChat
import RishiCore
import RishiReader
import RishiSettings
import RishiVoice

@MainActor
@Suite("ReaderVoiceEntry language wiring", .serialized)
struct ReaderVoiceEntryLanguageTests {

    private struct StubTokenProvider: TokenProvider {
        func token() async -> String? { nil }
    }

    private struct StubConversationStore: ConversationStore, @unchecked Sendable {
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

    private final class FakeMicPermissionGate: MicPermissionGate, @unchecked Sendable {
        private let decision: MicPermissionDecision
        init(decision: MicPermissionDecision) { self.decision = decision }
        func request() async -> MicPermissionDecision { decision }
    }

    private final class RecordingKeyFetcher: EphemeralKeyFetching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lastLanguage: String?
        func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
            lock.withLock { lastLanguage = language }
            return EphemeralKey(secret: "stub", sessionId: "sess")
        }
    }

    private final class FakeClient: RealtimeClientAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var status: RealtimeConnectionStatus = .disconnected

        func connect(
            ephemeralKey: String,
            bookContext: BookContextSnapshot?,
            language: String?
        ) async throws {
            lock.withLock { status = .connected }
        }

        func disconnect() async {
            lock.withLock { status = .disconnected }
        }

        func currentStatus() async -> RealtimeConnectionStatus {
            lock.withLock { status }
        }

        var providerCallId: String? { nil }

        func errorStream() -> AsyncStream<RealtimeClientError> {
            AsyncStream { continuation in continuation.finish() }
        }

        func transcriptStream() -> AsyncStream<RealtimeTranscriptEvent> {
            AsyncStream { continuation in continuation.finish() }
        }

        func toolCallStream() -> AsyncStream<RealtimeToolCallEvent> {
            AsyncStream { continuation in continuation.finish() }
        }

        func sendToolResult(callId: String, payload: String) async throws {}
    }

    @Test("presentVoice forwards the selected voice language through the presenter")
    func presentVoiceForwardsLanguage() async {
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let fakeClient = FakeClient()
        let keyFetcher = RecordingKeyFetcher()
        let userId = UUID()
        let presenter = rishi.VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: WorkerClient(
                baseURL: URL(string: "https://example.invalid")!,
                tokenProvider: StubTokenProvider()
            ),
            messageStore: StubMessageStore(),
            conversationLookup: ConversationLookup(store: StubConversationStore()),
            userIdProvider: { userId },
            dirtyHook: StubDirtyHook(),
            micGate: FakeMicPermissionGate(decision: .granted),
            clientFactory: { fakeClient },
            keyFetcherFactory: { keyFetcher }
        )
        let entry = ReaderVoiceEntry(
            voicePresenter: presenter,
            voiceLanguageProvider: { .french },
            onRequestPaywall: { _ in }
        )

        let bookId = UUID()
        let context = ReaderVoiceContext(
            title: "The Book",
            author: "The Author",
            chapters: [],
            currentPage: nil,
            pageText: nil,
            activeParagraphText: nil
        )
        entry.presentVoice(bookId: bookId, context: context, initialQuote: nil)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if presenter.state.status == .live { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(keyFetcher.lastLanguage == VoiceLanguageOption.french.rawValue)
        #expect(presenter.currentLanguage == VoiceLanguageOption.french.rawValue)

        await presenter.end()
    }
}
