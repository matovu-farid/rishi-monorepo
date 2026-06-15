//
//  ReaderTTSBridgeLongLivedEngineTests.swift
//  rishiTests
//
//  Bug 1 (readaloud-nextprev-page): next/previous paragraph plays silently and,
//  after commit cdeac0cc1 (jump now awaits engine.stop()), HANGS on device.
//
//  Root cause (confirmed by reading the call path): a passage switch tears down
//  and restarts the whole AVAudioEngine + re-acquires the audio session per
//  passage. ReaderTTSBridge.jump() -> engine.stop() -> TTSEngine.stop ->
//  teardown (await decoder.finish()) + AVAudioEngineAdapter.stop(); then the
//  new passage's playCurrent() -> engine.start() -> TTSEngine.start ->
//  engine.attach() + engine.start(). On device, stopping the engine mid-render
//  blocks (the hang) and restarting with a churned session yields no live route
//  (the pre-fix silence).
//
//  TARGET INVARIANT (this test, RED on current code): a user-driven passage
//  switch must NOT stop / attach / (re)start the underlying AVAudioEngine. The
//  engine is started ONCE for the read-aloud session and stays running; a switch
//  only resets the player node and schedules the new passage's buffers.
//
//  This drives the REAL TTSEngine over a FakeAudioEngine (which records every
//  attach/start/stop), so the assertion is about the genuine engine lifecycle,
//  not the FakeTTSEngine seam. Deterministic: an InfiniteChunkSource keeps the
//  passage "in flight" so next() is a true mid-passage switch with no real audio.
//
//  This is a DETECTOR. The fix is the long-lived-engine refactor, which is
//  gated behind a checkpoint and NOT applied here.
//

import Foundation
import Testing
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge long-lived engine (bug 1 detector)")
@MainActor
struct ReaderTTSBridgeLongLivedEngineTests {

    /// Yields nothing and never finishes, so a started passage stays in flight —
    /// next() fires as a TRUE mid-passage switch (the only condition under which
    /// the stop/restart churn manifests).
    private struct InfiniteChunkSource: TTSChunkSource {
        func stream(request: TTSStreamRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { _ in }
        }
    }

    /// Bridge over the REAL TTSEngine plus the FakeAudioEngine we assert on.
    private struct Env {
        let bridge: ReaderTTSBridge
        let audio: FakeAudioEngine
    }

    @MainActor
    private func makeEnv() -> Env {
        let state = TTSPlaybackState()
        let audio = FakeAudioEngine()
        let coordinator = AudioSessionCoordinator(configurator: FakeAudioSessionConfigurator())
        let engine = TTSEngine(
            streamer: TTSStreamer(source: InfiniteChunkSource()),
            decoderFactory: { try MP3StreamDecoder(targetFormat: $0) },
            engine: audio,
            coordinator: coordinator,
            state: state
        )
        let bridge = ReaderTTSBridge(
            engine: engine,
            state: state,
            tracker: TTSPassageTracker(),
            prewarmer: TTSPrewarmer(source: InfiniteChunkSource()),
            settingsStore: InMemoryTTSSettingsStore(),
            userId: UserID(),
            onPassageChange: { _ in }
        )
        return Env(bridge: bridge, audio: audio)
    }

    private func count(_ calls: [FakeAudioEngine.Call], _ kind: FakeAudioEngine.Call) -> Int {
        calls.filter { $0 == kind }.count
    }

    /// Property: for a switch STARTING FROM several different paragraph indices,
    /// the long-lived engine must not be stopped / re-attached / (re)started.
    /// Parameterised over many start indices per the user's property-based
    /// requirement. We jump to `startIndex` first (an in-place switch on the
    /// long-lived engine), snapshot the lifecycle-call counts, then fire next()
    /// as a true mid-passage switch and assert the counts stay flat.
    @Test("a passage switch keeps the AVAudioEngine running: no stop/attach/(re)start (property-based over start indices)",
          arguments: Array(0..<5))
    func switchDoesNotChurnTheEngine(startIndex: Int) async {
        let env = makeEnv()
        // A page large enough that startIndex and startIndex+1 are both valid.
        let paragraphs = (0..<8).map { "p\($0)" }

        await env.bridge.start(paragraphs: paragraphs)
        // Wait until the engine has been brought up for passage 0 (attach+start
        // happen exactly once for the whole session).
        await waitUntil(timeout: 2) { count(env.audio.calls, .start) >= 1 }

        // Move to the start index for this case (also an in-place switch on the
        // long-lived engine). Wait for that switch's resetNode to land before
        // snapshotting (startIndex 0 is a no-op jump-to-current, so allow it).
        let resetsBeforeJump = count(env.audio.calls, .resetNode)
        await env.bridge.jump(to: startIndex)
        // jump always replays via playCurrent -> engine.start() -> resetPlayerNode
        // (engine already running), even for jump-to-current (startIndex 0).
        await waitUntil(timeout: 2) { count(env.audio.calls, .resetNode) > resetsBeforeJump }

        let stopsAfterStart = count(env.audio.calls, .stop)
        let attachesAfterStart = count(env.audio.calls, .attach)
        let startsAfterStart = count(env.audio.calls, .start)
        let resetsAfterStart = count(env.audio.calls, .resetNode)

        // NEXT while the current passage is still in flight == a true mid-passage
        // switch — the only condition under which the old stop/restart churn
        // manifested. With the long-lived engine the player node is reset
        // (recorded as .resetNode), never stop/start.
        await env.bridge.next()
        await waitUntil(timeout: 2) { count(env.audio.calls, .resetNode) > resetsAfterStart }

        let calls = env.audio.calls
        #expect(count(calls, .stop) == stopsAfterStart,
                "passage switch must NOT stop the AVAudioEngine; startIndex=\(startIndex) calls=\(calls)")
        #expect(count(calls, .attach) == attachesAfterStart,
                "passage switch must NOT re-attach the player node; startIndex=\(startIndex) calls=\(calls)")
        #expect(count(calls, .start) == startsAfterStart,
                "passage switch must NOT (re)start the AVAudioEngine; startIndex=\(startIndex) calls=\(calls)")
        // Positive invariant: the long-lived engine path resets the node instead.
        #expect(count(calls, .resetNode) >= 1,
                "a switch must reset the player node in place; startIndex=\(startIndex) calls=\(calls)")

        await env.bridge.stop()
    }
}
