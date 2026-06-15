//
//  ReaderTTSBridgeAdvanceTests.swift
//  rishiTests
//
//  Phase 29 plan 29-03 — bridge-level advance orchestration coverage (D4).
//
//  AdvanceWatcherDecisionTests already lock the PURE decision struct. Nothing,
//  until this file, drives the bridge's start/advance/playCurrent/stop loop
//  AROUND that decision. These tests construct a ReaderTTSBridge over the
//  FakeTTSEngine seam (29-01) and assert the reader advances through a
//  multi-paragraph page without error, including the prewarmed-fast path that
//  regressed in epub-tts-premature-stop round 2 (29-RESEARCH §3.3, §5.5).
//
//  No live audio, no network: FakeTTSEngine scripts TTSPlaybackState transitions
//  directly, and the TTSPassageTracker forwards currentPassageId into
//  onPassageChange. The watcher polls every 100ms, so tests poll a recorded box
//  until the expected passages land (waitUntil) rather than hard-sleeping.
//

import Foundation
import Testing
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge advance")
@MainActor
struct ReaderTTSBridgeAdvanceTests {

    @Test("advances 0 -> 1 -> 2 in order and tears down at the end")
    func advancesThroughParagraphsAndTearsDown() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        // Await the 100ms-poll advance loop forwarding all three passages.
        // NOTE: `sawTeardown` is unsuitable as the wait predicate — start()
        // calls stop() first, which fires onPassageChange(nil) immediately, so
        // sawTeardown is true before any advance happens. Wait on the real
        // advance instead.
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices == [0, 1, 2] }

        await env.bridge.stop()

        // Observed passages 0, 1, 2 in order, then a final nil (teardown).
        #expect(env.recorder.nonNilIndices == [0, 1, 2])
        #expect(env.recorder.sawTeardown)
        // No index ever outside the 0...2 page bounds.
        #expect(env.recorder.nonNilIndices.allSatisfy { (0...2).contains($0) })
        // No error/bail: the engine was never scripted to .error.
        #expect(env.state.status != .error)
    }

    /// epub-tts-premature-stop, round 2: paragraph 0 is synthesis-bound
    /// (.normal), but paragraphs 1 and 2 are PREWARMED cache-hits whose entire
    /// .loading->.playing->.stopped lifecycle elapses inside one 100ms poll. The
    /// watcher only ever observes a residual .stopped carrying the target
    /// passage id. The run MUST STILL advance to the end rather than stalling
    /// after index 0.
    @Test("prewarmedFast short paragraphs still advance (epub-tts-premature-stop round 2)")
    func prewarmedFastParagraphsStillAdvance() async {
        let env = makeBridge(engine: { state in
            FakeTTSEngine(
                state: state,
                default: .prewarmedFast,
                scriptsByPassageId: ["0": .normal]
            )
        })

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        // Wait on the real advance, not sawTeardown (true immediately due to the
        // start()-time stop()).
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices == [0, 1, 2] }

        await env.bridge.stop()

        // Did not stall after index 0 — reached index 2 and tore down.
        #expect(env.recorder.nonNilIndices.contains(2))
        #expect(env.recorder.nonNilIndices == [0, 1, 2])
        #expect(env.recorder.sawTeardown)
    }

    /// Chapter-boundary continuation: when the current batch (a chapter) is
    /// exhausted, the bridge must ASK for the next batch and keep playing it
    /// rather than tearing the session down. Reproduces the reported bug —
    /// read-aloud stops at the last paragraph of a chapter instead of crossing
    /// into the next chapter's first paragraph.
    @Test("continues into the next batch on exhaustion instead of stopping")
    func continuesIntoNextBatchOnExhaustion() async {
        // One further "chapter" of two paragraphs, then end-of-book ([]).
        let source = ExhaustionSource([["delta", "echo"]])
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .normal) },
            onExhausted: { source.next() }
        )

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        // 3 paragraphs of batch 1 + 2 of the continuation batch = 5 engine
        // starts ONCE continuation works. Today the bridge stops after 3.
        await waitUntil(timeout: 6) { startedPassageIds(env.engine).count == 5 }

        await env.bridge.stop()

        // Played all three of batch 1 then both of the continuation batch; the
        // continuation resets the passage index, so ids restart at "0".
        #expect(startedPassageIds(env.engine) == ["0", "1", "2", "0", "1"])
        // The bridge actually requested the next batch on exhaustion.
        #expect(source.callCount >= 1)
        #expect(env.state.status != .error)
    }

    /// End of book: when the continuation source returns `[]` (no further
    /// chapter), the bridge tears the session down exactly once and does not
    /// loop or keep the engine running.
    @Test("tears down at end of book when no further chapter is available")
    func tearsDownAtEndOfBook() async {
        let source = ExhaustionSource([]) // no further chapters
        let env = makeBridge(
            engine: { state in FakeTTSEngine(state: state, script: .normal) },
            onExhausted: { source.next() }
        )

        await env.bridge.start(paragraphs: ["alpha", "bravo"])

        await waitUntil(timeout: 5) { env.recorder.nonNilIndices == [0, 1] }
        // The exhausted batch must trigger a single request for more.
        await waitUntil(timeout: 2) { source.callCount >= 1 }

        await env.bridge.stop()

        // Only the two real paragraphs played; nothing fabricated past the end.
        #expect(startedPassageIds(env.engine) == ["0", "1"])
        #expect(source.callCount >= 1)
        #expect(env.recorder.sawTeardown)
    }

    @Test("bails on engine error without advancing past 0")
    func bailsOnErrorWithoutAdvancing() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .error) })

        await env.bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        // Give the watcher ample poll ticks; it must NOT advance to index 1.
        await waitUntil(timeout: 2) { env.state.status == .error }
        // A couple more ticks to prove no spurious advance follows the error.
        try? await Task.sleep(nanoseconds: 300_000_000)

        await env.bridge.stop()

        #expect(!env.recorder.nonNilIndices.contains(1))
        #expect(!env.recorder.nonNilIndices.contains(2))
    }
}

// MARK: - Shared test harness

/// A no-op TTSChunkSource so the bridge's `TTSPrewarmer` collaborator can be
/// constructed without a live WorkerClient. The prewarmer only drains bytes for
/// read-ahead; an empty stream is a valid no-op for these logic tests.
struct NoopChunkSource: TTSChunkSource {
    func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Records onPassageChange callbacks (both indices and the nil teardown) for
/// assertions. The bridge invokes onPassageChange on @MainActor, and the suites
/// here are @MainActor, so a plain class is sufficient (no cross-actor lock).
@MainActor
final class PassageChangeRecorder {
    private(set) var events: [Int?] = []

    func record(_ index: Int?) { events.append(index) }

    var nonNilIndices: [Int] { events.compactMap { $0 } }
    var sawTeardown: Bool { events.contains(where: { $0 == nil }) }
}

/// Bundle of the constructed bridge plus the collaborators tests assert against.
@MainActor
struct BridgeTestEnv {
    let bridge: ReaderTTSBridge
    let engine: FakeTTSEngine
    let state: TTSPlaybackState
    let recorder: PassageChangeRecorder
}

/// Construct a ReaderTTSBridge wired to a FakeTTSEngine (built by `engine` from
/// the shared TTSPlaybackState) and a recording onPassageChange. Mirrors the
/// 29-01 smoke-test construction.
@MainActor
func makeBridge(
    engine makeEngine: (TTSPlaybackState) -> FakeTTSEngine,
    onExhausted: @escaping () async -> [String] = { [] }
) -> BridgeTestEnv {
    let state = TTSPlaybackState()
    let engine = makeEngine(state)
    let tracker = TTSPassageTracker()
    let prewarmer = TTSPrewarmer(source: NoopChunkSource())
    let settingsStore = InMemoryTTSSettingsStore()
    let userId = UserID()

    let recorder = PassageChangeRecorder()
    let bridge = ReaderTTSBridge(
        engine: engine,
        state: state,
        tracker: tracker,
        prewarmer: prewarmer,
        settingsStore: settingsStore,
        userId: userId,
        onPassageChange: { index in recorder.record(index) },
        onParagraphsExhausted: onExhausted
    )

    return BridgeTestEnv(bridge: bridge, engine: engine, state: state, recorder: recorder)
}

/// Scripts successive batches of paragraphs handed back to the bridge when the
/// current batch is exhausted — a deterministic stand-in for "load the next
/// EPUB chapter". Yields each batch once in order, then `[]` (end of book).
@MainActor
final class ExhaustionSource {
    private var batches: [[String]]
    private(set) var callCount = 0

    init(_ batches: [[String]]) { self.batches = batches }

    func next() -> [String] {
        callCount += 1
        return batches.isEmpty ? [] : batches.removeFirst()
    }
}

/// Passage ids the engine was asked to `start`, in order (drops non-start
/// calls). The bridge uses `passageId = String(index)`, so a continuation that
/// resets the index restarts the ids at "0".
@MainActor
func startedPassageIds(_ engine: FakeTTSEngine) -> [String] {
    engine.calls.compactMap { call in
        if case .start(let id) = call { return id } else { return nil }
    }
}

/// Poll `predicate` every 50ms until it is true or `timeout` seconds elapse.
/// Used instead of a fixed hard-sleep so tests settle as soon as the 100ms
/// advance-watcher poll lands the expected state.
@MainActor
func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}
