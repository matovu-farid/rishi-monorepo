//
//  ReaderTTSBridgeSeamSmokeTests.swift
//  rishiTests
//
//  Phase 29 plan 29-01 — proves the TTS testability seam works.
//
//  Before this phase ReaderTTSBridge held a CONCRETE `TTSEngine` actor, which
//  drags in a live AVAudioEngine + a network-backed streamer the moment you try
//  to drive it. That made the bridge's paragraph-advance orchestration (the very
//  behaviour the user reports as broken) impossible to test at the bridge level.
//
//  29-RESEARCH.md §2 names a `TTSPlaying` protocol seam as the single
//  highest-value re-architecture for testability (D1 + D4). This smoke test is
//  the proof: it constructs a ReaderTTSBridge with a `FakeTTSEngine` (a
//  `TTSPlaying` conformer that scripts TTSPlaybackState transitions with zero
//  audio render and zero network) and drives `bridge.start(paragraphs:)`,
//  asserting `onPassageChange(0)` fires. The full 0->1->2 advance invariants land
//  in plan 29-03; here we only prove the seam is wired and the bridge is
//  constructible + drivable.
//

import Foundation
import Testing
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge seam")
@MainActor
struct ReaderTTSBridgeSeamSmokeTests {

    /// A no-op TTSChunkSource so the bridge's `TTSPrewarmer` collaborator can be
    /// constructed without a live WorkerClient. The prewarmer only drains bytes
    /// for read-ahead; an empty stream is a valid no-op for the seam smoke test.
    private struct NoopChunkSource: TTSChunkSource {
        func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    @Test("bridge is constructible with a fake engine and emits passage zero")
    func bridge_is_constructible_with_fake_engine_and_emits_passage_zero() async {
        let state = TTSPlaybackState()
        let engine = FakeTTSEngine(state: state)
        let tracker = TTSPassageTracker()
        let prewarmer = TTSPrewarmer(source: NoopChunkSource())
        let settingsStore = InMemoryTTSSettingsStore()
        let userId = UserID()

        let recorder = PassageRecorder()
        let bridge = ReaderTTSBridge(
            engine: engine,
            state: state,
            tracker: tracker,
            prewarmer: prewarmer,
            settingsStore: settingsStore,
            userId: userId,
            onPassageChange: { index in
                if let index { recorder.record(index) }
            }
        )

        await bridge.start(paragraphs: ["alpha", "bravo", "charlie"])

        // The fake drives state.status -> .playing with currentPassageId = "0",
        // which the tracker forwards through passageStream() to onPassageChange.
        // Poll briefly for the async tracker hop to land.
        for _ in 0..<50 {
            if recorder.recorded.contains(0) { break }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        await bridge.stop()

        #expect(recorder.recorded.contains(0))
    }
}

/// Main-actor-isolated index recorder for the onPassageChange closure. The
/// bridge invokes onPassageChange on @MainActor (it writes the reader VM's
/// @Observable index), and this whole suite is @MainActor, so a plain class is
/// sufficient — no cross-actor lock needed.
@MainActor
private final class PassageRecorder {
    private(set) var recorded: [Int] = []
    func record(_ index: Int) { recorded.append(index) }
}
