//
//  ReadAheadCoordinatorTests.swift
//  rishiTests
//
//  Phase 34 plan 34-08 — SRP extraction. Locks the read-ahead window math +
//  warm/cancelAll lockstep that moved out of ReaderTTSBridge into
//  `ReadAheadCoordinator`. The coordinator drives a real `TTSPrewarmer` over a
//  recording `TTSChunkSource`, so these tests assert the EXACT request windows
//  the coordinator hands the prewarmer (text + nil passageId) without any live
//  audio or network. Behaviour must match the pre-extraction inline lockstep:
//  window = paragraphs[(index+1)..<min(index+1+readAhead, count)], and an empty
//  slice still goes through warm([]) (a no-op, asserted as "no requests").
//

import Foundation
import Testing
import RishiAudio
@testable import rishi

@Suite("ReadAheadCoordinator")
@MainActor
struct ReadAheadCoordinatorTests {

    /// Captures every `TTSStreamRequest` the prewarmer is asked to drain.
    /// Actor-isolated so the prewarmer's per-request Tasks can append safely.
    actor RecordingChunkSource: TTSChunkSource {
        private(set) var requested: [TTSStreamRequest] = []

        nonisolated func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
            Task { await self.append(request) }
            return AsyncThrowingStream { $0.finish() }
        }

        private func append(_ request: TTSStreamRequest) { requested.append(request) }

        func snapshot() -> [TTSStreamRequest] { requested }
    }

    /// Poll until `source` has recorded at least `count` requests (the prewarmer
    /// spawns a Task per request, so recording is asynchronous) or timeout.
    private func waitForRequests(
        _ source: RecordingChunkSource,
        count: Int,
        timeout: TimeInterval = 2
    ) async -> [TTSStreamRequest] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let snap = await source.snapshot()
            if snap.count >= count { return snap }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await source.snapshot()
    }

    @Test("warms exactly the next readAhead paragraphs after the play head")
    func warmsWindowAfterIndex() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 2)
        let paragraphs = ["a", "b", "c", "d", "e"]

        await coordinator.warm(after: 0, in: paragraphs, voice: "v", speed: 1.0)

        let requested = await waitForRequests(source, count: 2)
        // index 0 -> window [1, 2) of size readAhead=2 -> paragraphs "b", "c".
        #expect(requested.map { $0.text } == ["b", "c"])
        // Prewarm requests carry a nil passageId (not link-back tracked).
        #expect(requested.allSatisfy { $0.passageId == nil })
        #expect(requested.allSatisfy { $0.voice == "v" && $0.speed == 1.0 })
    }

    @Test("clamps the window to the end of the batch")
    func clampsWindowAtEnd() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 5)
        let paragraphs = ["a", "b", "c"]

        // index 1 -> window [2, min(7, 3)) = [2, 3) -> just "c".
        await coordinator.warm(after: 1, in: paragraphs, voice: "v", speed: 1.0)

        let requested = await waitForRequests(source, count: 1)
        #expect(requested.map { $0.text } == ["c"])
    }

    @Test("warms nothing at the last paragraph (empty window)")
    func emptyWindowAtLastParagraph() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 5)
        let paragraphs = ["a", "b", "c"]

        // index 2 is the last paragraph -> window [3, 3) is empty -> warm([]).
        await coordinator.warm(after: 2, in: paragraphs, voice: "v", speed: 1.0)

        // Give any (erroneous) spawned drains a chance to record, then assert none.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let requested = await source.snapshot()
        #expect(requested.isEmpty)
    }

    @Test("cancelAll completes cleanly and leaves the coordinator reusable")
    func cancelAllIsCleanAndReusable() async {
        let source = RecordingChunkSource()
        let coordinator = ReadAheadCoordinator(prewarmer: TTSPrewarmer(source: source), readAhead: 3)

        // index 0 -> window ["b", "c", "d"]; the recording streams finish
        // immediately so the prewarm Tasks drain on their own.
        await coordinator.warm(after: 0, in: ["a", "b", "c", "d"], voice: "v", speed: 1.0)
        await coordinator.cancelAll()  // must not crash / deadlock

        // The coordinator is still usable after cancelAll: a fresh warm records
        // its new window through the same prewarmer. Poll specifically for "y"
        // since the first warm's "b"/"c"/"d" requests are already recorded.
        await coordinator.warm(after: 0, in: ["x", "y"], voice: "v", speed: 1.0)
        let deadline = Date().addingTimeInterval(2)
        var sawY = false
        while Date() < deadline {
            if await source.snapshot().contains(where: { $0.text == "y" }) {
                sawY = true
                break
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(sawY)
    }
}
