//
//  VoiceSessionPresenterFailureAlertTests.swift
//  rishiTests
//
//  Regression for the native-alert migration: a startup failure (e.g. mic
//  permission already denied, which `RealtimeVoiceSession.start()` reports
//  SYNCHRONOUSLY) must dismiss the voice cover AND must never leave the cover
//  stranded on a repeat attempt.
//
//  The bug: `enterFailure` keyed its idempotency guard off `failure` (the
//  alert binding). On the first failure the alert never actually presented
//  (it collided with the cover dismissal on the same view), so `clearFailure`
//  never ran and `failure` stayed non-nil. The SECOND press then hit the
//  `guard failure == nil` early-return BEFORE flipping `isPresenting` off,
//  leaving the cover mounted over a blank `Color.clear` — the "black screen".
//

import Testing
import Foundation
import RishiCore
import RishiAudio
import RishiAPI
import RishiChat
import RishiVoice
@testable import rishi

@MainActor
@Suite("VoiceSessionPresenter failure alert", .serialized)
struct VoiceSessionPresenterFailureAlertTests {

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
            clientFactory: { UITestFakeRealtimeClient() },
            keyFetcherFactory: { UITestFakeEphemeralKeyFetcher() }
        )
    }

    @Test("a startup failure dismisses the cover and surfaces an alert")
    func micDenied_dismissesCoverAndSurfacesFailure() async {
        let presenter = makePresenter()
        await presenter.start(bookId: UUID())

        #expect(presenter.isPresenting == false)
        #expect(presenter.pendingFailure != nil || presenter.failure != nil)
    }

    @Test("a repeated startup failure never strands the voice cover")
    func repeatedMicDenied_doesNotStrandCover() async {
        let presenter = makePresenter()

        // Press 1.
        await presenter.start(bookId: UUID())
        #expect(presenter.isPresenting == false)

        // Press 2, WITHOUT the alert having been dismissed (in the bug the
        // alert never showed, so clearFailure() never ran). The cover must
        // still end up dismissed rather than stuck on a blank screen.
        await presenter.start(bookId: UUID())
        #expect(presenter.isPresenting == false)
    }
}
