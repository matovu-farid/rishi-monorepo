//
//  ParagraphAdvanceWatcher.swift
//  rishi (Phase 34 plan 34-08 — SRP extraction from ReaderTTSBridge)
//
//  Owns the paragraph auto-advance watcher that ReaderTTSBridge previously
//  implemented inline: the `advanceTask` poll loop + cadence and the pure
//  `AdvanceWatcherDecision` it drives. Single responsibility: poll
//  `TTSPlaybackState` on a fixed cadence and decide, per observed status, when
//  the current paragraph has finished and the host should advance (or bail on
//  error). The host supplies the `onAdvance` continuation; the watcher does not
//  know about transport, prewarm, or paging.
//

import Foundation
import RishiAudio

/// Pure decision logic for the paragraph advance watcher, factored out of
/// `ReaderTTSBridge.startAdvanceWatcher` so it can be unit-tested without a
/// live `TTSEngine` / audio render cycle.
///
/// The watcher polls `TTSPlaybackState.status` on a fixed cadence and must
/// decide, per observed status, whether to advance to the next paragraph,
/// bail on error, or keep waiting. Feed it the polled statuses in order via
/// `observe(_:)`.
///
/// Race fix (epub-tts-premature-stop, round 1): advancement is gated on having
/// first observed the current paragraph START (`.loading` OR `.playing`). It
/// MUST accept `.loading` and not only `.playing` — `.playing` lasts only as
/// long as the audio renders, so a very short paragraph (e.g. a heading) can
/// render its single buffer in under one poll interval and never be observed in
/// the `.playing` state.
///
/// Round 2 (no-advance regression): the round-1 ".loading is reliably > one
/// poll interval" assumption holds only for the FIRST chunk. Chunk N>=1 is
/// PREWARMED — its mp3 is already cached, so `.loading` is a fast cache hit and
/// the entire `.loading`->`.playing`->`.stopped` lifecycle of a short prewarmed
/// paragraph can elapse inside a single 100ms poll sleep. The watcher then sees
/// a residual `.stopped` with no start observed and, treating it as pre-start
/// residual, waits forever. Playback halts after one chunk.
///
/// The robust fix is to key advancement off PASSAGE IDENTITY, which the engine
/// exposes as a STABLE post-condition rather than a transient. `TTSEngine` sets
/// `TTSPlaybackState.currentPassageId` to the playing passage's id on its first
/// buffer and leaves it set through the `.stopped` that ends that passage. So
/// `(status == .stopped, currentPassageId == targetPassageId)` persists until
/// the NEXT passage's first buffer and survives any poll gap. Construct the
/// decision with `targetPassageId` and feed `observe(status:passageId:)`.
///
/// The legacy status-only `observe(_:)` path (no target id) is retained for
/// callers/tests that don't track passage identity; it keeps the round-1
/// started-gate behaviour.
struct AdvanceWatcherDecision {

    enum Action: Equatable {
        case wait
        case advance
        case bail
    }

    private let targetPassageId: String?
    private var hasStarted = false

    /// Status-only watcher (round-1 behaviour). Advances on the first
    /// `.stopped` seen AFTER a start (`.loading`/`.playing`) was observed.
    init() {
        self.targetPassageId = nil
    }

    /// Passage-identity-aware watcher (round-2 fix). Advances on a `.stopped`
    /// whose `currentPassageId` matches `targetPassageId` — a stable
    /// post-condition that does not require catching the transient start — or,
    /// as a fallback, on a `.stopped` (with nil/cleared id) once the target
    /// passage's start was observed.
    init(targetPassageId: String) {
        self.targetPassageId = targetPassageId
    }

    /// Legacy status-only entry point. Equivalent to
    /// `observe(status:passageId:)` with a nil passage id.
    mutating func observe(_ status: TTSStatus) -> Action {
        observe(status: status, passageId: nil)
    }

    /// Process the next polled `(status, currentPassageId)` and return the
    /// action to take.
    mutating func observe(status: TTSStatus, passageId: String?) -> Action {
        if status == .error {
            return .bail
        }

        // Arm the started-gate when we see our passage begin. With a target id
        // we only count a start that belongs to our passage; without one (legacy
        // path) any start arms the gate.
        if status == .loading || status == .playing {
            if targetPassageId == nil || passageId == targetPassageId {
                hasStarted = true
            }
        }

        if status == .stopped {
            // Primary, race-proof signal: a `.stopped` carrying our passage id
            // means our passage actually played and finished — advance even if
            // we never caught its transient start (prewarmed fast path).
            if let target = targetPassageId, passageId == target {
                return .advance
            }
            // Fallback: started-gate. Covers the legacy status-only path and the
            // case where the id was cleared (teardown) after our start was seen.
            if hasStarted {
                return .advance
            }
        }

        return .wait
    }
}

/// Polls `TTSPlaybackState` for the `.stopped` transition that signals the
/// current paragraph's buffers have all drained, then invokes `onAdvance`.
/// Owns the single in-flight `advanceTask` so the bridge no longer carries the
/// polling concern. Polling cadence matches TTSEngine's own state-update
/// cadence (the await sleep yields back to the main runloop so SwiftUI
/// rendering interleaves).
@MainActor
final class ParagraphAdvanceWatcher {

    private let state: TTSPlaybackState
    private var advanceTask: Task<Void, Never>?

    init(state: TTSPlaybackState) {
        self.state = state
    }

    /// Begin watching for the `.stopped` of `targetPassageId`. Cancels any
    /// in-flight watch first (a new watch supersedes the old). On the decision
    /// reaching `.advance`, `onAdvance` is invoked exactly once and the loop
    /// exits; on `.bail` (engine error) the loop exits without advancing.
    ///
    /// See `AdvanceWatcherDecision` for the gating rationale. Round 2: we key
    /// advancement off PASSAGE IDENTITY — a `.stopped` carrying our target
    /// passage id is a stable post-condition that survives the 100ms poll gap,
    /// so a short PREWARMED chunk whose whole lifecycle elapses inside one poll
    /// sleep is still honoured (epub-tts-premature-stop, round 2).
    func start(targetPassageId: String, onAdvance: @escaping () async -> Void) {
        advanceTask?.cancel()
        // KEEP: F-P0-06 audit — explicit @MainActor required to read
        // `state.status` (the @Observable TTSPlaybackState lives on main).
        // Body sleeps 100ms between poll ticks; the await sleep yields
        // back to the main runloop so SwiftUI rendering interleaves.
        advanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var decision = AdvanceWatcherDecision(targetPassageId: targetPassageId)
            while !Task.isCancelled {
                switch decision.observe(
                    status: self.state.status,
                    passageId: self.state.currentPassageId
                ) {
                case .advance:
                    await onAdvance()
                    return
                case .bail:
                    return
                case .wait:
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }
        }
    }

    /// Cancel the in-flight watch (if any). Idempotent. Mirrors the bridge's
    /// old `advanceTask?.cancel(); advanceTask = nil` ordering at call sites
    /// (cancel BEFORE stopping the engine / switching batches — race fix).
    func cancel() {
        advanceTask?.cancel()
        advanceTask = nil
    }
}
