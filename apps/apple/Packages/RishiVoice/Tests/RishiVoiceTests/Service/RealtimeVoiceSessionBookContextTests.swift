import Testing
import Foundation
@testable import RishiVoice
@testable import RishiAudio
import RishiCore
import RishiCore
import RishiSearch

/// Tests for Plan 25-10 — `RealtimeVoiceSession.start(bookId:currentPage:…)`
/// extended signature, Responder lifecycle (spawn-on-start + cancel-on-end),
/// embedder pre-warm running in parallel with the key fetch.
///
/// `.serialized` for the same reason as `RealtimeVoiceSessionTests`: the actor
/// + state inspection across the audio coordinator + Responder Task can't run
/// in parallel safely.
@MainActor
@Suite("RealtimeVoiceSessionBookContext", .serialized)
struct RealtimeVoiceSessionBookContextTests {

    // MARK: - bookId == nil: no Responder, no prewarm, nil snapshot

    @Test("start() with bookId=nil: responderFactory NOT invoked")
    func startWithoutBookId_doesNotSpawnResponder() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "en")

        #expect(fakes.state.status == .live)
        #expect(fakes.responderFactoryBox.callCount() == 0)
        #expect(fakes.responderFactoryBox.lastBookId() == nil)
        #expect(fakes.fetcher.lastLanguage() == "en")
    }

    @Test("start() with bookId=nil: embedderPrewarm NOT invoked")
    func startWithoutBookId_doesNotPrewarm() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "en")

        // Allow any (incorrectly fired) parallel prewarm task to land.
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(fakes.prewarmBox.callCount() == 0)
    }

    @Test("start() with bookId=nil: fetcher receives nil snapshot")
    func startWithoutBookId_fetcherGetsNilSnapshot() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "en")

        #expect(fakes.fetcher.lastBookContext() == nil)
    }

    // MARK: - bookId != nil: Responder spawned, prewarm fired, snapshot threaded through

    @Test("start(bookId:) invokes responderFactory with the same UUID")
    func startWithBookId_spawnsResponderWithBookId() async throws {
        let fakes = makeSession(micDecision: .granted)
        let bookId = UUID()
        await fakes.session.start(language: "en", bookId: bookId)

        #expect(fakes.state.status == .live)
        #expect(fakes.responderFactoryBox.callCount() == 1)
        #expect(fakes.responderFactoryBox.lastBookId() == bookId)

        // Tidy up so the responder task doesn't outlive the test.
        await fakes.session.end()
    }

    @Test("start(bookId:) invokes embedderPrewarm exactly once")
    func startWithBookId_invokesPrewarm() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "en", bookId: UUID())

        // Allow the parallel prewarm Task to complete.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(fakes.prewarmBox.callCount() == 1)

        await fakes.session.end()
    }

    @Test("start(bookId:currentPage:outline:) threads snapshot into fetcher")
    func startWithBookContext_passesSnapshotToFetcher() async throws {
        let fakes = makeSession(micDecision: .granted)
        let bookId = UUID()
        let outline = BookOutlineDTO(
            title: "Test Title",
            author: "Test Author",
            chapters: ["Ch1", "Ch2"]
        )
        await fakes.session.start(
            language: "en",
            bookId: bookId,
            currentPage: 42,
            pageText: "page body",
            outline: outline,
            activeParagraphText: "paragraph body"
        )

        let snapshot = fakes.fetcher.lastBookContext()
        #expect(snapshot != nil)
        #expect(snapshot?.bookId == bookId)
        #expect(snapshot?.currentPage == 42)
        #expect(snapshot?.pageText == "page body")
        #expect(snapshot?.outline == outline)
        #expect(snapshot?.activeParagraphText == "paragraph body")
        #expect(fakes.fetcher.lastLanguage() == "en")
        #expect(fakes.client.connectBookContexts.count == 1)
        #expect(fakes.client.connectBookContexts[0] == snapshot)

        await fakes.session.end()
    }

    // MARK: - end() cancels the Responder task so subsequent injected events are NOT processed

    @Test("end() halts responder consumption — events injected after end() are not processed")
    func endHaltsResponderConsumption() async throws {
        let fakes = makeSession(micDecision: .granted)
        await fakes.session.start(language: "en", bookId: UUID())

        // Responder is consuming the fake client's tool-call stream against
        // the stub BookSearch. Drive ONE tool call BEFORE end() to confirm
        // the wiring is live (the responder will write a tool result).
        fakes.client.inject(toolCall: RealtimeToolCallEvent(
            callId: "before-end",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"hello\"}"
        ))

        // Give the responder a moment to handle the inbound event.
        try await Task.sleep(nanoseconds: 100_000_000)
        let resultsBeforeEnd = fakes.client.sentToolResultsSnapshot()
        #expect(resultsBeforeEnd.count == 1, "Pre-end wiring sanity")

        // End the session. This cancels the responder task AND disconnects the
        // client (which finishes the stream). The responder consume loop must
        // terminate so any subsequent inject is ignored.
        await fakes.session.end()

        // After end(): the client is disconnected, the stream is finished,
        // and the responder task is cancelled. Calling inject(toolCall:) now
        // is a no-op because FakeRealtimeClient.disconnect() finished the
        // continuation; the responder cannot receive new events. Even if the
        // event were queued for replay, the stream finished so the for-await
        // loop has exited.
        fakes.client.inject(toolCall: RealtimeToolCallEvent(
            callId: "after-end",
            name: "bookContext",
            argumentsJSON: "{\"queryText\":\"world\"}"
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        let resultsAfterEnd = fakes.client.sentToolResultsSnapshot()
        // No new result for the post-end event.
        #expect(resultsAfterEnd.count == 1)
        #expect(resultsAfterEnd.first?.callId == "before-end")
    }

    // MARK: - Parallel prewarm vs serial: parallel must be measurably faster

    @Test("embedderPrewarm runs in parallel with key fetch (not serial)")
    func prewarmRunsInParallelWithKeyFetch() async throws {
        // Key fetch sleeps 150 ms; prewarm sleeps 150 ms. If they were serial
        // the whole start() would take ~300 ms; in parallel it should finish
        // closer to 150 ms (we use 280 ms as a generous upper bound to keep the
        // test deterministic on noisy CI hosts).
        let delayedFetcher = DelayingKeyFetcher(delayMillis: 150)
        let delayedPrewarm = DelayingPrewarmBox(delayMillis: 150)
        let fakes = makeSession(
            micDecision: .granted,
            fetcher: delayedFetcher,
            prewarmBox: delayedPrewarm
        )

        let start = Date()
        await fakes.session.start(language: "en", bookId: UUID())
        let elapsed = Date().timeIntervalSince(start)

        #expect(fakes.state.status == .live)
        // Parallel: roughly max(150, 150) = ~150 ms, well below 280 ms.
        // Serial: ~300 ms, well above 280 ms. 280 ms is the discrimination band.
        #expect(elapsed < 0.280,
                "start() took \(elapsed)s — expected <0.28s for parallel prewarm + key fetch")
        #expect(delayedPrewarm.callCount() == 1)

        await fakes.session.end()
    }

    // MARK: - Builders

    struct Fakes {
        let session: RealtimeVoiceSession
        let state: VoiceSessionState
        let coordinator: AudioSessionCoordinator
        let client: FakeRealtimeClient
        let fetcher: any BookContextCapturingFetcher
        let prewarmBox: PrewarmCallBox
        let responderFactoryBox: ResponderFactoryBox
    }

    @MainActor
    private func makeSession(
        micDecision: MicPermissionDecision,
        fetcher: (any BookContextCapturingFetcher)? = nil,
        prewarmBox: PrewarmCallBox? = nil
    ) -> Fakes {
        let state = VoiceSessionState()
        let configurator = FakeAudioSessionConfigurator()
        let coordinator = AudioSessionCoordinator(configurator: configurator)
        let client = FakeRealtimeClient()
        let micGate = FakeMicPermissionGate(decision: micDecision)
        let usedFetcher: any BookContextCapturingFetcher = fetcher ?? CapturingEphemeralKeyFetcher(
            result: .success(.init(secret: "k", sessionId: "s"))
        )
        let usedPrewarm = prewarmBox ?? PrewarmCallBox()
        let responderFactoryBox = ResponderFactoryBox(client: client)

        let session = RealtimeVoiceSession(
            micGate: micGate,
            coordinator: coordinator,
            keyFetcher: usedFetcher,
            client: client,
            state: state,
            responderFactory: responderFactoryBox.factory(),
            embedderPrewarm: usedPrewarm.prewarmClosure(),
            backoff: { _ in .zero },
            maxReconnects: 3
        )
        return Fakes(
            session: session,
            state: state,
            coordinator: coordinator,
            client: client,
            fetcher: usedFetcher,
            prewarmBox: usedPrewarm,
            responderFactoryBox: responderFactoryBox
        )
    }
}

// MARK: - Test doubles

/// Shared surface for the two test fetcher variants so the `Fakes` struct can
/// hold either one and tests can read `lastBookContext()` / `lastLanguage()`
/// from both.
protocol BookContextCapturingFetcher: EphemeralKeyFetching {
    func lastBookContext() -> BookContextSnapshot?
    func lastLanguage() -> String?
}

/// Captures the last `(language, bookContext)` pair handed to `fetch`.
/// Stub variants in `RealtimeVoiceSessionTests.swift` discard the snapshot;
/// this one keeps it for assertions.
final class CapturingEphemeralKeyFetcher: BookContextCapturingFetcher, @unchecked Sendable {

    private let lock = NSLock()
    private let result: Result<EphemeralKey, Error>
    private var _lastLanguage: String?
    private var _lastBookContext: BookContextSnapshot?
    private var _callCount: Int = 0

    init(result: Result<EphemeralKey, Error>) {
        self.result = result
    }

    func lastLanguage() -> String? { lock.withLock { _lastLanguage } }
    func lastBookContext() -> BookContextSnapshot? { lock.withLock { _lastBookContext } }
    func callCount() -> Int { lock.withLock { _callCount } }

    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        lock.withLock {
            _lastLanguage = language
            _lastBookContext = bookContext
            _callCount += 1
        }
        return try result.get()
    }
}

/// Capturing fetcher with a configurable sleep so the parallel-prewarm test
/// can prove the key fetch and the prewarm overlap.
final class DelayingKeyFetcher: BookContextCapturingFetcher, @unchecked Sendable {

    private let delayMillis: Int
    private let lock = NSLock()
    private var _lastLanguage: String?
    private var _lastBookContext: BookContextSnapshot?

    init(delayMillis: Int) {
        self.delayMillis = delayMillis
    }

    func lastBookContext() -> BookContextSnapshot? { lock.withLock { _lastBookContext } }
    func lastLanguage() -> String? { lock.withLock { _lastLanguage } }

    func fetch(language: String?, bookContext: BookContextSnapshot?) async throws -> EphemeralKey {
        lock.withLock {
            _lastLanguage = language
            _lastBookContext = bookContext
        }
        try await Task.sleep(nanoseconds: UInt64(delayMillis) * 1_000_000)
        return EphemeralKey(secret: "k", sessionId: "s")
    }
}

/// Records every invocation of the `embedderPrewarm` closure handed to
/// `RealtimeVoiceSession.init`. Closure body is a no-op so tests stay fast;
/// the `DelayingPrewarmBox` subclass overrides for the parallel-timing test.
class PrewarmCallBox: @unchecked Sendable {

    private let lock = NSLock()
    private var _callCount: Int = 0

    func callCount() -> Int { lock.withLock { _callCount } }

    fileprivate func recordCall() {
        lock.withLock { _callCount += 1 }
    }

    func prewarmClosure() -> @Sendable () async -> Void {
        let box = self
        return { @Sendable in
            box.recordCall()
            await box.body()
        }
    }

    /// Override-point for delayed variants. Default is a no-op.
    fileprivate func body() async {
        // no-op
    }
}

/// Prewarm box variant that sleeps inside its closure so the parallel-timing
/// test can prove `start()` ran prewarm + fetcher concurrently.
final class DelayingPrewarmBox: PrewarmCallBox, @unchecked Sendable {

    private let delayMillis: Int

    init(delayMillis: Int) {
        self.delayMillis = delayMillis
        super.init()
    }

    override fileprivate func body() async {
        try? await Task.sleep(nanoseconds: UInt64(delayMillis) * 1_000_000)
    }
}

/// Records every Responder factory invocation and returns a real
/// `BookContextResponder` wired to the test's FakeRealtimeClient + a stub
/// BookSearch (`.ready` status, empty hits — so tool calls land as a `[]`
/// JSON payload via `sendToolResult`).
@MainActor
final class ResponderFactoryBox {

    private let client: FakeRealtimeClient
    private let stubSearch: StubBookSearch
    private var _callCount: Int = 0
    private var _lastBookId: UUID?

    init(client: FakeRealtimeClient) {
        self.client = client
        // status: .ready + non-empty hits so the responder writes a JSON
        // array payload back, which the endHaltsResponderConsumption test
        // uses to confirm the wiring is live before end() lands.
        self.stubSearch = StubBookSearch(
            hits: [BookSearchHit(text: "stub", page: 1, score: 0.5)],
            status: .ready
        )
    }

    func callCount() -> Int { _callCount }
    func lastBookId() -> UUID? { _lastBookId }

    func factory() -> RealtimeVoiceSession.BookContextResponderFactory {
        let weakSelf = self
        let client = self.client
        let stubSearch = self.stubSearch
        return { bookId in
            // Record on MainActor so tests can read state without races.
            Task { @MainActor in
                weakSelf._callCount += 1
                weakSelf._lastBookId = bookId
            }
            return BookContextResponder(
                client: client,
                search: stubSearch,
                bookId: bookId
            )
        }
    }
}
