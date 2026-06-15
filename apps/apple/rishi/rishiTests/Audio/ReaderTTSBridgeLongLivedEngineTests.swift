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
import PropertyBased
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

    /// Property (PropertyBased): for ANY page geometry — a generated page size
    /// and a generated valid start index — a mid-passage next() switch must not
    /// stop / re-attach / (re)start the long-lived engine; it only resets the
    /// player node in place. Generated + shrunk rather than a fixed index set.
    @Test("a passage switch keeps the AVAudioEngine running: no stop/attach/(re)start (property-based)")
    func switchDoesNotChurnTheEngine() async {
        await propertyCheck(count: 12, input: Gen.int(in: 3 ... 10), Gen.int(in: 0 ... 8)) { pageCount, rawStart in
            // Clamp the generated start so both startIndex and startIndex+1 exist.
            let startIndex = max(0, min(rawStart, pageCount - 2))
            let env = makeEnv()
            let paragraphs = (0..<pageCount).map { "p\($0)" }

            await env.bridge.start(paragraphs: paragraphs)
            // Engine brought up for passage 0 (attach+start happen exactly once).
            await waitUntil(timeout: 2) { count(env.audio.calls, .start) >= 1 }

            // Move to the start index (an in-place switch on the long-lived
            // engine). jump always replays via engine.start() -> resetPlayerNode.
            let resetsBeforeJump = count(env.audio.calls, .resetNode)
            await env.bridge.jump(to: startIndex)
            await waitUntil(timeout: 2) { count(env.audio.calls, .resetNode) > resetsBeforeJump }

            let stopsAfterStart = count(env.audio.calls, .stop)
            let attachesAfterStart = count(env.audio.calls, .attach)
            let startsAfterStart = count(env.audio.calls, .start)
            let resetsAfterStart = count(env.audio.calls, .resetNode)

            // NEXT while the passage is in flight == a true mid-passage switch.
            await env.bridge.next()
            await waitUntil(timeout: 2) { count(env.audio.calls, .resetNode) > resetsAfterStart }

            let calls = env.audio.calls
            #expect(count(calls, .stop) == stopsAfterStart,
                    "switch must NOT stop the engine; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")
            #expect(count(calls, .attach) == attachesAfterStart,
                    "switch must NOT re-attach; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")
            #expect(count(calls, .start) == startsAfterStart,
                    "switch must NOT (re)start the engine; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")
            #expect(count(calls, .resetNode) >= 1,
                    "a switch must reset the player node in place; pageCount=\(pageCount) startIndex=\(startIndex) calls=\(calls)")

            await env.bridge.stop()
        }
    }
}
