//
//  ReaderTTSBridge.swift
//  rishi (Phase 8 plan 08-06, Phase 24 plan 24-03)
//
//  Orchestrates paragraph-at-a-time TTS playback for a reader VM, with
//  read-ahead prewarm of the next `readAhead` paragraphs. Each paragraph
//  is sent as a separate TTSEngine.start(request:) with a stable
//  passageId = String(index). The bridge listens to TTSPassageTracker's
//  passageStream() and forwards passage index updates to the reader VM
//  extension setter (currentReadAloudPassageIndex).
//
//  Phase 24 (D6): the bridge owns the lockstep contract — when it fires
//  `engine.start(request: paragraph_N)` it ALSO calls
//  `prewarmer.warm(requests: window)` where
//  `window = paragraphs[(N+1)..<min(N+1+readAhead, count)]`. Sequential
//  advance (N -> N+1) re-issues warm for the new window without cancelling
//  (already-cached paragraphs no-op via the cache layer's de-dup, D5). On
//  pause / stop / non-sequential jump the bridge calls
//  `prewarmer.cancelAll()` before the next playback start.
//
//  Lifetime: the host (RootView) creates one bridge per reader sheet and
//  retains it for the sheet's lifetime; `stop()` is awaited before drop.
//

import Foundation
import Observation
import RishiAudio
import RishiCore

// `AdvanceWatcherDecision` (the pure poll-decision struct) and the polling
// `ParagraphAdvanceWatcher` that drives it now live in
// `ParagraphAdvanceWatcher.swift`. The read-ahead prewarm lockstep lives in
// `ReadAheadCoordinator.swift`. ReaderTTSBridge orchestrates both as internal
// collaborators it constructs itself (so the public init below is unchanged).

@MainActor
final class ReaderTTSBridge {

    // Phase 29 (29-01): retargeted from the concrete `TTSEngine` actor to the
    // `any TTSPlaying` seam so the bridge can be driven by a FakeTTSEngine in
    // tests with no live audio render cycle and no network. A `TTSEngine` still
    // satisfies `any TTSPlaying`, so AppDependencies compiles unchanged.
    private let engine: any TTSPlaying
    private let state: TTSPlaybackState
    private let tracker: TTSPassageTracker
    private let settingsStore: any TTSSettingsStore
    private let userId: UserID
    private let onPassageChange: (Int?) -> Void

    /// Polls `TTSPlaybackState` and decides when the current paragraph has
    /// finished so the bridge should advance. Internal collaborator the bridge
    /// constructs itself (extracted by plan 34-08).
    private let advanceWatcher: ParagraphAdvanceWatcher

    /// Owns the read-ahead window math + `warm`/`cancelAll` lockstep against the
    /// prewarmer. Internal collaborator the bridge constructs itself (extracted
    /// by plan 34-08).
    private let readAhead: ReadAheadCoordinator

    /// Source of the NEXT batch of paragraphs when the current batch is
    /// exhausted. For EPUB this loads the next reading-order resource (the next
    /// chapter) so read-aloud continues across chapter boundaries instead of
    /// halting at the last paragraph of a chapter; it returns `[]` at the end of
    /// the book. The default (`{ [] }`) preserves single-batch behaviour for
    /// callers (e.g. PDF) that do not stream further paragraphs.
    private let onParagraphsExhausted: () async -> [String]

    /// Source of the PREVIOUS batch of paragraphs when the user presses Previous
    /// on the FIRST paragraph of the current batch. Symmetric to
    /// `onParagraphsExhausted`: for EPUB it loads the preceding reading-order
    /// resource (the previous chapter), for PDF the preceding page with
    /// selectable text. Returns `[]` at the very start of the book/document (no
    /// preceding batch), which the bridge treats as "stay put". On a non-empty
    /// result the bridge lands on the LAST paragraph of that batch (mirroring how
    /// a reader expects Previous-at-page-top to resume the bottom of the prior
    /// page). The default (`{ [] }`) preserves clamped single-batch behaviour.
    private let onParagraphsBeforeStart: () async -> [String]

    private var paragraphs: [String] = []
    private var currentIndex = 0
    private var consumeTask: Task<Void, Never>?

    init(
        engine: any TTSPlaying,
        state: TTSPlaybackState,
        tracker: TTSPassageTracker,
        prewarmer: TTSPrewarmer,
        settingsStore: any TTSSettingsStore,
        userId: UserID,
        onPassageChange: @escaping (Int?) -> Void,
        onParagraphsExhausted: @escaping () async -> [String] = { [] },
        onParagraphsBeforeStart: @escaping () async -> [String] = { [] }
    ) {
        self.engine = engine
        self.state = state
        self.tracker = tracker
        self.settingsStore = settingsStore
        self.userId = userId
        self.onPassageChange = onPassageChange
        self.onParagraphsExhausted = onParagraphsExhausted
        self.onParagraphsBeforeStart = onParagraphsBeforeStart
        // Internal collaborators (plan 34-08). The bridge constructs them from
        // the same injected `state` / `prewarmer` so the PUBLIC init signature is
        // unchanged — AppDependencies.makeAudioStack wires the bridge identically.
        self.advanceWatcher = ParagraphAdvanceWatcher(state: state)
        self.readAhead = ReadAheadCoordinator(prewarmer: prewarmer)
    }

    // MARK: - Public surface

    /// Begin reading `paragraphs` from the first index. If a session is
    /// already active, it is stopped first. No-op when `paragraphs` is empty.
    func start(paragraphs: [String]) async {
        await stop()
        guard !paragraphs.isEmpty else { return }
        self.paragraphs = paragraphs
        self.currentIndex = 0
        await tracker.attach(state: state)
        startConsumingPassages()
        startAdvanceWatcher()
        await playCurrent()
    }

    /// Restart the advance watcher for the current play head. Delegates the
    /// poll loop to `ParagraphAdvanceWatcher`; the bridge supplies the target
    /// passage id (the engine plays paragraph `currentIndex` with
    /// `passageId = String(currentIndex)`, see `playCurrent`) and the advance
    /// continuation.
    private func startAdvanceWatcher() {
        advanceWatcher.start(targetPassageId: String(currentIndex)) { [weak self] in
            await self?.advance()
        }
    }

    /// Stop the active session (if any). Idempotent. Phase 24 (D6): cancels
    /// any in-flight prewarms before stopping the engine.
    func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        await engine.stop()
        await tracker.detach()
        paragraphs = []
        currentIndex = 0
        onPassageChange(nil)
    }

    /// Pause the underlying engine (paragraph position is preserved). Phase
    /// 24 (D6): cancels in-flight prewarms — the user has stopped the
    /// playback head's forward motion, so the read-ahead window is stale.
    /// On `resume()` the bridge does NOT automatically re-warm; the next
    /// `playCurrent()` after sequential advance will.
    func pause() async {
        await readAhead.cancelAll()
        await engine.pause()
    }

    /// Resume the underlying engine.
    func resume() async {
        await engine.resume()
    }

    /// Jump to a specific paragraph index (non-sequential). Phase 24 (D6):
    /// cancels in-flight prewarms, stops the engine, then restarts playback
    /// at the new index. The fresh `playCurrent()` re-issues warm for the
    /// new window. No-op if `index` is out of range.
    func jump(to index: Int) async {
        guard index >= 0, index < paragraphs.count else { return }
        // Cancel the in-flight advance watcher BEFORE stopping the engine.
        // engine.stop() sets status .stopped while currentPassageId stays set,
        // which the live watcher would read as "current passage finished" and
        // fire advance() concurrently with this jump — racing currentIndex and
        // playCurrent (observed as an index-out-of-range crash on repeat).
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        // Long-lived engine: do NOT stop the engine on a switch. The previous
        // approach (full engine.stop() + session release per passage) HUNG on
        // device when stopping mid-render, and the restarted engine had no live
        // route (silent next/prev). Now playCurrent() -> engine.start() performs
        // an in-place switch: TTSEngine resets the player node and schedules the
        // new passage's buffers WITHOUT attach/start/stop and WITHOUT churning
        // the session. The advanceTask-cancel-before-switch ordering above stays
        // (race fix). Locked by ReaderTTSBridgeLongLivedEngineTests +
        // ReaderTTSBridgeNextPrevTests.nextDoesNotReactivateSession.
        currentIndex = index
        startAdvanceWatcher()
        await playCurrent()
    }

    /// User-driven: skip forward to the next paragraph and play it. Clamped at
    /// the last paragraph of the current page/resource (a no-op there). The
    /// reader view follows via `onPassageChange`, turning the page when the
    /// target paragraph is off-screen.
    func next() async {
        if currentIndex + 1 >= paragraphs.count {
            // Last paragraph of the current chapter: cross into the next chapter
            // via the SAME continuation auto-advance uses, so the forward button
            // and auto-advance behave identically at a boundary (no variance).
            await advanceToNextBatch()
        } else {
            await jump(to: currentIndex + 1)
        }
    }

    /// User-driven: skip back to the previous paragraph and play it. At the
    /// FIRST paragraph of the current batch, cross BACKWARD into the previous
    /// batch (previous chapter / page) via the same continuation source, landing
    /// on its LAST paragraph — symmetric to how `next()` crosses forward at the
    /// last paragraph. With no previous batch (start of book) this stays put.
    func previous() async {
        if currentIndex == 0 {
            await retreatToPreviousBatch()
        } else {
            await jump(to: currentIndex - 1)
        }
    }

    /// User-driven: replay the current paragraph from its start (e.g. the
    /// listener missed it). No-op when there is no active session.
    func repeatCurrent() async {
        await jump(to: currentIndex)
    }

    // MARK: - Internals

    private func startConsumingPassages() {
        consumeTask?.cancel()
        // KEEP: F-P0-06 audit — explicit @MainActor required so the
        // onPassageChange(_:) callback (which writes the @Observable
        // currentReadAloudPassageIndex on the reader VM) executes on
        // main. Body chains an AsyncStream from the tracker actor.
        consumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.tracker.passageStream()
            for await passageId in stream {
                guard let index = Int(passageId) else { continue }
                self.onPassageChange(index)
            }
        }
    }

    private func playCurrent() async {
        guard currentIndex < paragraphs.count else { return }
        let settings = await settingsStore.load(userId: userId)
        // Re-validate after the await: a racing stop()/jump() may have emptied
        // `paragraphs` or moved `currentIndex` while we were suspended.
        guard currentIndex < paragraphs.count else { return }
        let paragraph = paragraphs[currentIndex]
        let request = TTSStreamRequest(
            text: paragraph,
            voice: settings.voice,
            speed: settings.speed,
            passageId: String(currentIndex)
        )
        // Phase 24 (D6) — fire prewarm for the next window BEFORE the
        // engine start so the warmer's Tasks are queued ahead of the
        // playback await. We don't await warm's completion — warm only
        // awaits to spawn per-request Tasks; the drains run independently.
        // End-of-page (window slice empty) still goes through warm([]) so
        // the lockstep call site is uniform. Window math + warm lockstep are
        // owned by `ReadAheadCoordinator` (plan 34-08).
        await readAhead.warm(
            after: currentIndex,
            in: paragraphs,
            voice: settings.voice,
            speed: settings.speed
        )
        await engine.start(request: request)
    }

    private func advance() async {
        currentIndex += 1
        if currentIndex >= paragraphs.count {
            // End of the current batch (e.g. an EPUB chapter) — cross into the
            // next one.
            await advanceToNextBatch()
        } else {
            startAdvanceWatcher()
            await playCurrent()
        }
    }

    /// Loads the next batch of paragraphs (e.g. the next EPUB chapter) via
    /// `onParagraphsExhausted` and starts it from paragraph 0; an empty result
    /// means end-of-book and tears the session down. Shared by auto-advance and
    /// the user-driven Next button so a chapter boundary behaves identically for
    /// both. Cancels the current advance watcher and stale prewarms before the
    /// switch (mirrors `jump`) so the old chapter's watcher cannot fire against
    /// the new index.
    @discardableResult
    private func advanceToNextBatch() async -> Bool {
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        let next = await onParagraphsExhausted()
        guard !next.isEmpty else {
            await stop()
            return false
        }
        paragraphs = next
        currentIndex = 0
        startAdvanceWatcher()
        await playCurrent()
        return true
    }

    /// Loads the PREVIOUS batch (e.g. the previous EPUB chapter / PDF page) via
    /// `onParagraphsBeforeStart` and starts it from its LAST paragraph — where a
    /// listener expects narration to resume when stepping back across a boundary.
    /// An empty result means start-of-book: stay put (do NOT tear down) so the
    /// current paragraph keeps playing. Mirrors `advanceToNextBatch` but lands on
    /// the last index instead of 0, and no-ops (rather than stops) when dry.
    ///
    /// Loads BEFORE cancelling the watcher: the dry case must leave current
    /// playback — and its advance watcher — untouched, so we only tear down the
    /// old watcher once we know there IS a previous batch to switch to. (The
    /// forward path can cancel first because it always either advances or stops;
    /// backward-at-start uniquely needs to preserve the live session.)
    @discardableResult
    private func retreatToPreviousBatch() async -> Bool {
        let previous = await onParagraphsBeforeStart()
        guard !previous.isEmpty else { return false }
        advanceWatcher.cancel()
        await readAhead.cancelAll()
        paragraphs = previous
        currentIndex = previous.count - 1
        startAdvanceWatcher()
        await playCurrent()
        return true
    }
}
