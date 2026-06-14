//
//  ReaderTTSBridgePageNavTests.swift
//  rishiTests
//
//  Phase 29 plan 29-03 — ported Electron page-navigation / bleed / stuck-loop
//  invariants (D5). 29-RESEARCH §4 maps each practical Electron Playwright spec
//  (tts-page-navigation.spec.ts et al — read-only reference, NOT modified) to an
//  iOS ReaderTTSBridge logic equivalent. These are deterministic Swift-Testing
//  tests over the FakeTTSEngine seam (29-01): no live audio, no network.
//
//  The Electron suite's durable value is the page-navigation state invariants:
//  a new page resets the play head to paragraph 0, the OLD engine session is
//  torn down BEFORE the new start (no old-audio bleed), the highlight is always
//  within the current page's bounds, an empty start is a no-op (the stuck-loop
//  guard), and jump targets the requested paragraph. Each @Test below traces to
//  its Electron source.
//
//  Reuses the makeBridge / waitUntil / PassageChangeRecorder harness defined in
//  ReaderTTSBridgeAdvanceTests.swift (same test target).
//

import Foundation
import Testing
import RishiAudio
import RishiCore
@testable import rishi

@Suite("ReaderTTSBridge page navigation")
@MainActor
struct ReaderTTSBridgePageNavTests {

    /// Port of "Next-page refreshes player paragraphs" (tts-page-navigation.spec):
    /// starting the bridge with a NEW paragraph list resets the index to 0 and
    /// re-emits passage 0.
    @Test("new page refreshes paragraphs and resets to passage 0 (port of tts-page-navigation.spec)")
    func newPageResetsToPassageZero() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b"])
        // Let the first page advance at least to passage 1 so a reset is observable.
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices.contains(1) }

        let countBeforeSecondStart = env.recorder.events.count
        await env.bridge.start(paragraphs: ["x", "y", "z"])
        // Wait for a real passage index after the reset — not just any event:
        // start() fires onPassageChange(nil) via its internal stop() first, which
        // would satisfy a bare count check before passage 0 is forwarded.
        await waitUntil(timeout: 5) { !env.recorder.nonNilIndices(after: countBeforeSecondStart).isEmpty }

        // The FIRST onPassageChange after the second start is index 0 (reset).
        let afterReset = env.recorder.nonNilIndices(after: countBeforeSecondStart)
        #expect(afterReset.first == 0)
        // The fake's last Call.start carried passageId "0".
        #expect(env.engine.lastStartedPassageId == "0")

        await env.bridge.stop()
    }

    /// Port of "Loading pauses old audio BEFORE fetch" / "Next pauses OLD audio
    /// immediately": calling start while a session is active tears down the OLD
    /// engine session (Call.stop) BEFORE the new Call.start("0"). No old-audio
    /// bleed.
    @Test("page change tears down old session before new start (no bleed)")
    func pageChangeTearsDownOldSessionBeforeNewStart() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b"])
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices.contains(0) }

        // Start a NEW page while the previous session is active.
        await env.bridge.start(paragraphs: ["x", "y", "z"])

        // There is a Call.stop (teardown) recorded BEFORE the start("0") that
        // begins the new page.
        let calls = env.engine.calls
        guard let newStartIdx = calls.lastIndex(of: .start(passageId: "0")) else {
            Issue.record("expected a start for passage 0 on the new page")
            await env.bridge.stop()
            return
        }
        let teardownBeforeNewStart = calls[..<newStartIdx].contains(.stop)
        #expect(teardownBeforeNewStart)

        await env.bridge.stop()
    }

    /// Port of "INVARIANT: highlight always on visible page": across the whole
    /// run of a 3-paragraph page, every non-nil onPassageChange index is within
    /// 0 <= index < 3.
    @Test("highlight is always within the current page bounds")
    func highlightAlwaysWithinPageBounds() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b", "c"])
        await waitUntil(timeout: 5) { env.recorder.sawTeardown }

        #expect(env.recorder.nonNilIndices.allSatisfy { 0 <= $0 && $0 < 3 })

        await env.bridge.stop()
    }

    /// Port of "T2 stuck-loop reproducer" -> bridge.start([]) is a no-op
    /// (ReaderTTSBridge early-return guard). No onPassageChange fires and no
    /// Call.start is recorded.
    @Test("start with empty paragraphs is a no-op (stuck-loop guard, port of T2)")
    func startWithEmptyParagraphsIsNoOp() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: [])
        // Give any errant watcher a few ticks to (incorrectly) fire.
        try? await Task.sleep(nanoseconds: 300_000_000)

        #expect(env.recorder.nonNilIndices.isEmpty)
        let startedSomething = env.engine.calls.contains { call in
            if case .start = call { return true }
            return false
        }
        #expect(!startedSomething)
    }

    /// Port of "resume-paragraph / read-aloud-from-selection": jump(to: k) plays
    /// index k — the next Call.start carries passageId "k" and onPassageChange
    /// observes k.
    @Test("jump(to: k) plays paragraph k (port of resume-paragraph / read-aloud-from-selection)")
    func jumpPlaysTargetParagraph() async {
        let env = makeBridge(engine: { state in FakeTTSEngine(state: state, script: .normal) })

        await env.bridge.start(paragraphs: ["a", "b", "c", "d"])
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices.contains(0) }

        let countBeforeJump = env.recorder.events.count
        await env.bridge.jump(to: 2)
        await waitUntil(timeout: 5) { env.recorder.nonNilIndices(after: countBeforeJump).contains(2) }

        #expect(env.engine.lastStartedPassageId == "2")
        #expect(env.recorder.nonNilIndices.contains(2))

        await env.bridge.stop()
    }
}

// MARK: - Harness extensions used by the page-nav assertions

extension FakeTTSEngine {
    /// The passageId of the most recent `.start` call, or nil if none.
    var lastStartedPassageId: String? {
        for call in calls.reversed() {
            if case let .start(passageId) = call { return passageId }
        }
        return nil
    }
}

extension PassageChangeRecorder {
    /// Non-nil indices recorded AFTER the first `count` events — used to inspect
    /// what happened since a marker (e.g. the second start / a jump).
    func nonNilIndices(after count: Int) -> [Int] {
        guard count <= events.count else { return [] }
        return events[count...].compactMap { $0 }
    }
}
