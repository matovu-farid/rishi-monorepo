//
//  AdvanceWatcherDecisionTests.swift
//  rishiTests
//
//  Regression: epub-tts-premature-stop.
//
//  EPUB read-aloud stopped after only the first (tiny heading) chunk once the
//  ParagraphChunker refinement made the first paragraph a short heading instead
//  of a long paragraph. Root cause: ReaderTTSBridge's advance watcher polls
//  TTSPlaybackState.status every 100ms and only advanced after it had OBSERVED
//  the transient `.playing` status. A short paragraph renders its single audio
//  buffer in under one poll interval, so `.playing` could fall entirely between
//  two polls — the watcher never set its "has started" flag and ignored the
//  `.stopped` that followed, stalling playback on the first chunk.
//
//  Fix: gate advancement on `.loading` OR `.playing` (`.loading` is
//  synthesis/decode-bound and reliably observable for every paragraph). These
//  tests lock the decision logic in deterministically, without a live engine.
//
//  Round 2 (no-advance regression): the `.loading`-gate fix only held for the
//  FIRST chunk. Chunk N>=1 is PREWARMED (drained into the cache ahead of the
//  play head), so its `.loading` is a fast cache hit, not synthesis-bound. The
//  whole `.loading`->`.playing`->`.stopped` lifecycle of a prewarmed short
//  paragraph can elapse inside the new watcher's first 100ms sleep — the watcher
//  wakes, sees a residual `.stopped` with `hasStarted=false`, treats it as
//  pre-start residual, and waits forever. Playback halts after exactly one
//  chunk.
//
//  Round 2 fix: make the decision PASSAGE-IDENTITY aware. The engine sets
//  TTSPlaybackState.currentPassageId to the playing passage's id on its first
//  buffer and leaves it set through the `.stopped` that ends that passage. So
//  `(status==.stopped, currentPassageId == myTargetId)` is a STABLE
//  post-condition that survives the poll gap — the watcher advances on it even
//  if it never caught the transient start. The status-only gate is retained as
//  a fallback for callers that don't supply a passage id.
//

import Foundation
import Testing
import RishiAudio
@testable import rishi

@Suite("AdvanceWatcherDecision")
@MainActor
struct AdvanceWatcherDecisionTests {

    /// The exact regression: a short paragraph whose poll sequence is
    /// `.loading` then `.stopped` — the `.playing` state was never observed
    /// because it elapsed between poll ticks. The watcher MUST still advance.
    @Test("advances on loading->stopped even when .playing was never observed")
    func advancesWhenPlayingNeverObserved() {
        var decision = AdvanceWatcherDecision()
        #expect(decision.observe(.loading) == .wait)
        #expect(decision.observe(.stopped) == .advance)
    }

    /// Normal long paragraph: loading -> playing -> stopped. Still advances.
    @Test("advances on the normal loading->playing->stopped sequence")
    func advancesOnNormalSequence() {
        var decision = AdvanceWatcherDecision()
        #expect(decision.observe(.loading) == .wait)
        #expect(decision.observe(.playing) == .wait)
        #expect(decision.observe(.playing) == .wait)
        #expect(decision.observe(.stopped) == .advance)
    }

    /// Residual `.stopped` from the previous session's teardown (seen BEFORE
    /// this paragraph has started) must NOT trigger an advance.
    @Test("does not advance off a residual .stopped seen before start")
    func ignoresResidualStoppedBeforeStart() {
        var decision = AdvanceWatcherDecision()
        #expect(decision.observe(.stopped) == .wait)
        #expect(decision.observe(.idle) == .wait)
        #expect(decision.observe(.loading) == .wait)
        #expect(decision.observe(.stopped) == .advance)
    }

    /// `.playing`-only start (no `.loading` ever polled) still arms the gate.
    @Test("advances when only .playing was observed before .stopped")
    func advancesWhenOnlyPlayingObserved() {
        var decision = AdvanceWatcherDecision()
        #expect(decision.observe(.playing) == .wait)
        #expect(decision.observe(.stopped) == .advance)
    }

    /// `.error` bails out without advancing.
    @Test("bails on .error")
    func bailsOnError() {
        var decision = AdvanceWatcherDecision()
        #expect(decision.observe(.loading) == .wait)
        #expect(decision.observe(.error) == .bail)
    }

    // MARK: - Round 2: passage-identity-aware advancement

    /// THE round-2 regression. A PREWARMED short paragraph (target id "1")
    /// runs its entire `.loading`->`.playing`->`.stopped` lifecycle inside the
    /// watcher's first 100ms sleep, so the watcher's FIRST poll already sees the
    /// terminal `.stopped` for its own passage — it never observed any start.
    /// With a target passage id, `(.stopped, "1")` is a stable post-condition
    /// that MUST advance, even though `hasStarted` was never set by a start.
    @Test("advances on .stopped for the target passage id even if start was never observed")
    func advancesOnStoppedForTargetPassageEvenWithoutObservedStart() {
        var decision = AdvanceWatcherDecision(targetPassageId: "1")
        #expect(decision.observe(status: .stopped, passageId: "1") == .advance)
    }

    /// A residual `.stopped` carrying the PREVIOUS passage's id ("0") — seen
    /// before this passage (target "1") has started — must NOT advance. This is
    /// the genuine pre-start residual the round-1 logic guarded against; passage
    /// identity makes the guard precise rather than relying on "no start seen."
    @Test("does not advance off a residual .stopped carrying a different passage id")
    func ignoresResidualStoppedForDifferentPassage() {
        var decision = AdvanceWatcherDecision(targetPassageId: "1")
        #expect(decision.observe(status: .stopped, passageId: "0") == .wait)
        #expect(decision.observe(status: .loading, passageId: "1") == .wait)
        #expect(decision.observe(status: .stopped, passageId: "1") == .advance)
    }

    /// Normal sequence with ids: loading/playing carry the target id, then a
    /// matching `.stopped` advances.
    @Test("advances on normal sequence when passage id matches throughout")
    func advancesOnNormalSequenceWithMatchingId() {
        var decision = AdvanceWatcherDecision(targetPassageId: "2")
        #expect(decision.observe(status: .loading, passageId: "2") == .wait)
        #expect(decision.observe(status: .playing, passageId: "2") == .wait)
        #expect(decision.observe(status: .stopped, passageId: "2") == .advance)
    }

    /// If the start was observed for the target passage, a `.stopped` with a
    /// nil currentPassageId (e.g. cleared by teardown) still advances — the
    /// started-gate fallback covers ids going missing at the very end.
    @Test("advances on .stopped with nil id when target start was observed")
    func advancesOnStoppedNilIdAfterObservedStart() {
        var decision = AdvanceWatcherDecision(targetPassageId: "3")
        #expect(decision.observe(status: .playing, passageId: "3") == .wait)
        #expect(decision.observe(status: .stopped, passageId: nil) == .advance)
    }

    /// `.error` still bails on the passage-aware path.
    @Test("bails on .error on the passage-aware path")
    func bailsOnErrorPassageAware() {
        var decision = AdvanceWatcherDecision(targetPassageId: "1")
        #expect(decision.observe(status: .loading, passageId: "1") == .wait)
        #expect(decision.observe(status: .error, passageId: "1") == .bail)
    }
}
