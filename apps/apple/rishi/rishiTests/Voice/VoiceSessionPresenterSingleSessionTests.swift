//
//  VoiceSessionPresenterSingleSessionTests.swift
//  rishiTests
//
//  Regression test for the "two voices / echo" bug: two voice sessions
//  connecting at once. `VoiceSessionPresenter.start()` must enforce a
//  single-session invariant by claiming `isPresenting` SYNCHRONOUSLY, before
//  its first suspension point (the conversation lookup). Otherwise two
//  re-entrant start() calls (a double-tapped toolbar voice button, or the
//  toolbar button and "Ask about this" firing together) both pass the guard
//  and each spin up a RealtimeVoiceSession -> two WebRTC audio streams.
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
@Suite("VoiceSessionPresenter single-session invariant", .serialized)
struct VoiceSessionPresenterSingleSessionTests {

    /// `ConversationStore` whose `conversations(for:)` suspends on its first
    /// call until the test cancels the awaiting task, while counting how many
    /// times it was entered. Lets the test freeze `start()` exactly at its
    /// first `await` and fire a second `start()` to prove the guard holds.
    final class BlockingConversationStore: ConversationStore, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var blocking: CheckedContinuation<Void, Error>?
        private var entered: CheckedContinuation<Void, Never>?
        private var cancelled = false

        var calls: Int { lock.withLock { _calls } }

        /// Resolves once the first `conversations(for:)` call has entered and
        /// suspended, so the test can assert state at that precise point.
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
            dirtyHook: StubDirtyHook()
        )
    }

    @Test("a second start() while the first is mid-lookup is a no-op — one session")
    func concurrentStartCreatesOneSession() async {
        let store = BlockingConversationStore()
        let presenter = makePresenter(store: store)

        // Task A enters start() and suspends inside the conversation lookup.
        let taskA = Task { await presenter.start(bookId: UUID()) }
        await store.waitUntilEntered()

        // The slot is claimed synchronously, before the first await.
        #expect(presenter.isPresenting == true)
        #expect(store.calls == 1)

        // Task B arrives while A is suspended. With the invariant it must bail
        // at the guard and never reach the lookup; without it, B would reach
        // the lookup and a second session would be created (calls == 2).
        await presenter.start(bookId: UUID())
        #expect(store.calls == 1)

        // Unwind A without driving it into the live-session / network path.
        taskA.cancel()
        _ = await taskA.value
    }
}
