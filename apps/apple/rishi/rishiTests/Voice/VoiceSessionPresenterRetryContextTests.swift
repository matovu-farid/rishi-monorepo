//
//  VoiceSessionPresenterRetryContextTests.swift
//  rishiTests
//
//  Regression test for the voice-retry context-loss bug. When a session
//  fails and the user taps Retry, the retried session must preserve the
//  book-context snapshot (title/author/page) and the prefilled quote that the
//  original `start(bookId:initialQuote:bookContext:)` was given — not restart
//  with only `bookId`, which produced a degraded session.
//
//  Drives the deterministic, no-network failure path: a `userIdProvider`
//  that returns `nil` makes `start` set status `.failed` and return early
//  AFTER storing the three context fields, so the test can assert they survive
//  across `retry()` without touching the conversation lookup or the worker.
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
@Suite("VoiceSessionPresenter retry preserves book context")
struct VoiceSessionPresenterRetryContextTests {

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

    /// Presenter whose `userIdProvider` returns `nil`, so `start` fails
    /// synchronously (no network, no lookup) right after storing context.
    private func makeSignedOutPresenter() -> VoiceSessionPresenter {
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let worker = WorkerClient(
            baseURL: URL(string: "https://example.invalid")!,
            tokenProvider: StubTokenProvider()
        )
        return VoiceSessionPresenter(
            coordinator: coordinator,
            workerClient: worker,
            messageStore: StubMessageStore(),
            conversationLookup: ConversationLookup(store: StubConversationStore()),
            userIdProvider: { nil },
            dirtyHook: StubDirtyHook()
        )
    }

    private func makeSnapshot(bookId: UUID) -> BookContextSnapshot {
        BookContextSnapshot(
            bookId: bookId,
            currentPage: 42,
            pageText: "the quick brown fox",
            outline: BookOutlineDTO(
                title: "A Title",
                author: "An Author",
                chapters: ["One", "Two"]
            ),
            activeParagraphText: "active paragraph"
        )
    }

    @Test("start stores the book context even when it fails")
    func startStoresBookContext() async {
        let presenter = makeSignedOutPresenter()
        let bookId = UUID()
        let snapshot = makeSnapshot(bookId: bookId)

        await presenter.start(bookId: bookId, bookContext: snapshot)

        #expect(presenter.currentBookContext == snapshot)
        #expect(presenter.state.status == .failed(reason: .unknown("Sign in required")))
    }

    @Test("retry preserves the book context and the initial quote")
    func retryPreservesBookContextAndQuote() async {
        let presenter = makeSignedOutPresenter()
        let bookId = UUID()
        let snapshot = makeSnapshot(bookId: bookId)
        let quote = "ask about this passage"

        await presenter.start(
            bookId: bookId,
            initialQuote: quote,
            bookContext: snapshot
        )
        #expect(presenter.currentBookContext == snapshot)
        #expect(presenter.pendingInitialQuote == quote)

        await presenter.retry()

        // The retried (also-failing) session must have re-applied the same
        // context, not dropped it back to bookId-only.
        #expect(presenter.currentBookContext == snapshot)
        #expect(presenter.pendingInitialQuote == quote)
        #expect(presenter.currentBookId == bookId)
        #expect(presenter.state.status == .failed(reason: .unknown("Sign in required")))
    }
}
