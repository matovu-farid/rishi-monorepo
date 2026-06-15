//
//  ReaderTTSBridgeNextPrevTests.swift
//  rishiTests
//
//  Feature 5 — user-driven previous/next PARAGRAPH navigation on the read-aloud
//  player. These tests are written before ReaderTTSBridge.next()/previous()
//  exist (TDD red). The FakeTTSEngine `.holds` script keeps the engine in
//  `.playing` so the auto-advance watcher never fires; only the explicit
//  next()/previous() calls move the play head, which makes the navigation
//  deterministic. Assertions read the fake's ordered start-call log.
//

import Foundation
import Testing
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge next/previous")
@MainActor
struct ReaderTTSBridgeNextPrevTests {

    /// The passage ids the engine was asked to START, in order.
    private func startIds(_ engine: FakeTTSEngine) -> [String?] {
        engine.calls.compactMap { call in
            if case .start(let passageId) = call { return passageId }
            return nil
        }
    }

    @Test("next() advances one paragraph, previous() goes back, each plays the target")
    func nextAndPreviousNavigate() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "2" }

        await env.bridge.previous()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        await env.bridge.stop()
        #expect(startIds(env.engine) == ["0", "1", "2", "1"])
    }

    @Test("next() at the last paragraph is a clamped no-op (no cross-resource yet)")
    func nextAtEndClamps() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["only-a", "only-b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        // At the last paragraph: must not start an out-of-range "2".
        await env.bridge.next()
        try? await Task.sleep(nanoseconds: 250_000_000)

        await env.bridge.stop()
        #expect(startIds(env.engine) == ["0", "1"])
    }

    @Test("next() fully stops then plays the new passage (same path as auto-advance)")
    func nextStopsThenPlaysNewPassage() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        let stopsBefore = env.engine.calls.filter { $0 == .stop }.count
        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }
        let stopsAfter = env.engine.calls.filter { $0 == .stop }.count

        // Device evidence (next/prev silent): leaving the session active on a
        // switch (switchPassage no-op, no re-activate) means the AVAudioEngine is
        // stopped and restarted with no live route -> the whole stream/decoder
        // pipeline never starts. Auto-advance works precisely because it does a
        // FULL stop (releasing the session) then a fresh start that re-activates.
        // A jump must take that same path: stop, then play the new passage.
        #expect(stopsAfter > stopsBefore, "next() must fully stop (release session) before playing the new passage")
        #expect(startIds(env.engine).last == "1", "next() must then start the new passage")
        await env.bridge.stop()
    }

    @Test("repeatCurrent() replays the current paragraph from its start")
    func repeatCurrentReplays() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.repeatCurrent()
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0", "0"] }

        await env.bridge.next()
        await waitUntil(timeout: 2) { startIds(env.engine).last == "1" }

        await env.bridge.repeatCurrent()
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0", "0", "1", "1"] }

        await env.bridge.stop()
    }

    @Test("previous() at the first paragraph is a clamped no-op")
    func previousAtStartClamps() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .holds) })
        await env.bridge.start(paragraphs: ["a", "b"])
        await waitUntil(timeout: 2) { startIds(env.engine) == ["0"] }

        await env.bridge.previous()
        try? await Task.sleep(nanoseconds: 250_000_000)

        await env.bridge.stop()
        #expect(startIds(env.engine) == ["0"])
    }
}
