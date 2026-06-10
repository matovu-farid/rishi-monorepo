//
//  ReaderTTSBridge.swift
//  rishi (Phase 8 plan 08-06)
//
//  Orchestrates sentence-at-a-time TTS playback for a reader VM. Each
//  sentence is sent as a separate TTSEngine.start(request:) with a stable
//  passageId = String(index). The bridge listens to TTSPassageTracker's
//  passageStream() and forwards passage index updates to the reader VM
//  extension setter (currentReadAloudPassageIndex).
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
    private let settingsStore: any TTSSettingsStore
    private let userId: UserID
    private let onPassageChange: (Int?) -> Void

    private var sentences: [String] = []
    private var currentIndex = 0
    private var consumeTask: Task<Void, Never>?
    private var advanceTask: Task<Void, Never>?

    init(
        engine: TTSEngine,
        state: TTSPlaybackState,
        tracker: TTSPassageTracker,
        settingsStore: any TTSSettingsStore,
        userId: UserID,
        onPassageChange: @escaping (Int?) -> Void
    ) {
        self.engine = engine
        self.state = state
        self.tracker = tracker
        self.settingsStore = settingsStore
        self.userId = userId
        self.onPassageChange = onPassageChange
    }

    // MARK: - Public surface

    /// Begin reading `sentences` from the first index. If a session is
    /// already active, it is stopped first. No-op when `sentences` is empty.
    func start(sentences: [String]) async {
        await stop()
        guard !sentences.isEmpty else { return }
        self.sentences = sentences
        self.currentIndex = 0
        await tracker.attach(state: state)
        startConsumingPassages()
        startAdvanceWatcher()
        await playCurrent()
    }

    /// Stop the active session (if any). Idempotent.
    func stop() async {
        consumeTask?.cancel()
        consumeTask = nil
        advanceTask?.cancel()
        advanceTask = nil
        await engine.stop()
        await tracker.detach()
        sentences = []
        currentIndex = 0
        onPassageChange(nil)
    }

    /// Pause the underlying engine (sentence position is preserved).
    func pause() async {
        await engine.pause()
    }

    /// Resume the underlying engine.
    func resume() async {
        await engine.resume()
    }

    // MARK: - Internals

    private func startConsumingPassages() {
        consumeTask?.cancel()
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
    /// the current sentence's buffers have all drained, then advances to
    /// the next sentence. Polling cadence matches TTSEngine's own
    /// state-update cadence (50ms in NowPlayingController + tracker).
    private func startAdvanceWatcher() {
        advanceTask?.cancel()
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
        guard currentIndex < sentences.count else { return }
        let settings = await settingsStore.load(userId: userId)
        let sentence = sentences[currentIndex]
        let request = TTSStreamRequest(
            text: sentence,
            voice: settings.voice,
            speed: settings.speed,
            passageId: String(currentIndex)
        )
        await engine.start(request: request)
    }

    private func advance() async {
        currentIndex += 1
        if currentIndex >= sentences.count {
            await stop()
        } else {
            startAdvanceWatcher()
            await playCurrent()
        }
    }
}
