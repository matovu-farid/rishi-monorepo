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

@MainActor
final class ReaderTTSBridge {

    private let engine: TTSEngine
    private let state: TTSPlaybackState
    private let tracker: TTSPassageTracker
    private let prewarmer: TTSPrewarmer
    private let settingsStore: any TTSSettingsStore
    private let userId: UserID
    private let onPassageChange: (Int?) -> Void

    /// Number of paragraphs to prewarm ahead of the current play head.
    /// Phase 24 (D1): default 5; configurable knob.
    var readAhead: Int = 5

    private var paragraphs: [String] = []
    private var currentIndex = 0
    private var consumeTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?

    init(
        engine: TTSEngine,
        state: TTSPlaybackState,
        tracker: TTSPassageTracker,
        prewarmer: TTSPrewarmer,
        settingsStore: any TTSSettingsStore,
        userId: UserID,
        onPassageChange: @escaping (Int?) -> Void
    ) {
        self.engine = engine
        self.state = state
        self.tracker = tracker
        self.prewarmer = prewarmer
        self.settingsStore = settingsStore
        self.userId = userId
        self.onPassageChange = onPassageChange
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

    /// Stop the active session (if any). Idempotent. Phase 24 (D6): cancels
    /// any in-flight prewarms before stopping the engine.
    func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        advanceTask?.cancel()
        advanceTask = nil
        await prewarmer.cancelAll()
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
        await prewarmer.cancelAll()
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
        await prewarmer.cancelAll()
        await engine.stop()
        currentIndex = index
        startAdvanceWatcher()
        await playCurrent()
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

    /// Watches `state.status` for the .stopped transition that signals
    /// the current paragraph's buffers have all drained, then advances to
    /// the next paragraph. Polling cadence matches TTSEngine's own
    /// state-update cadence (50ms in NowPlayingController + tracker).
    private func startAdvanceWatcher() {
        advanceTask?.cancel()
        // KEEP: F-P0-06 audit — explicit @MainActor required to read
        // `state.status` (the @Observable TTSPlaybackState lives on main).
        // Body sleeps 100ms between poll ticks; the await sleep yields
        // back to the main runloop so SwiftUI rendering interleaves.
        advanceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Wait for the engine to leave .loading and enter .playing first
            // (we don't want to advance off the loading→stopped no-op state).
            var hasStartedPlaying = false
            while !Task.isCancelled {
                let status = self.state.status
                if status == .playing {
                    hasStartedPlaying = true
                }
                if hasStartedPlaying, status == .stopped {
                    await self.advance()
                    return
                }
                if status == .error {
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }

    private func playCurrent() async {
        guard currentIndex < paragraphs.count else { return }
        let settings = await settingsStore.load(userId: userId)
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
        // the lockstep call site is uniform.
        let windowStart = currentIndex + 1
        let upper = min(windowStart + readAhead, paragraphs.count)
        if windowStart < upper {
            let window = paragraphs[windowStart..<upper].map { text in
                TTSStreamRequest(
                    text: text,
                    voice: settings.voice,
                    speed: settings.speed,
                    passageId: nil
                )
            }
            await prewarmer.warm(requests: window)
        } else {
            await prewarmer.warm(requests: [])
        }
        await engine.start(request: request)
    }

    private func advance() async {
        currentIndex += 1
        if currentIndex >= paragraphs.count {
            await stop()
        } else {
            startAdvanceWatcher()
            await playCurrent()
        }
    }
}
