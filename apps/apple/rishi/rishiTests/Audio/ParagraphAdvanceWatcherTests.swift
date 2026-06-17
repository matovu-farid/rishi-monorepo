//
//  ParagraphAdvanceWatcherTests.swift
//  rishiTests
//
//  Phase 34 plan 34-08 — SRP extraction. AdvanceWatcherDecisionTests already
//  lock the PURE decision struct; these tests lock the POLLING wrapper
//  (`ParagraphAdvanceWatcher`) that moved out of ReaderTTSBridge: it polls a
//  real `TTSPlaybackState` on the 100ms cadence and invokes `onAdvance` exactly
//  once when the decision reaches `.advance`, bails (no advance) on `.error`,
//  and stops cleanly on `cancel()`. No live engine — the test scripts the
//  observable state directly, mirroring how FakeTTSEngine drives it.
//

import Foundation
import Testing
import RishiAudio
@testable import rishi

@Suite("ParagraphAdvanceWatcher")
@MainActor
struct ParagraphAdvanceWatcherTests {

    /// Records how many times the advance continuation fired.
    @MainActor
    final class AdvanceRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    @Test("advances once when the target passage reaches .stopped")
    func advancesOnTargetStopped() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        // Simulate the engine playing then finishing passage "0".
        state.status = .loading
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "0") { recorder.record() }

        // Transition to the stable post-condition the watcher keys off.
        state.status = .stopped // currentPassageId stays "0"

        await waitUntil(timeout: 3) { recorder.count == 1 }
        #expect(recorder.count == 1)

        // The loop returns after a single advance — no spurious repeats.
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(recorder.count == 1)
        watcher.cancel()
    }

    @Test("does not advance off a residual .stopped for a different passage")
    func ignoresResidualStoppedForDifferentPassage() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        // Residual terminal state from the PREVIOUS passage "0" while we wait on "1".
        state.status = .stopped
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "1") { recorder.record() }

        // Several poll intervals pass with the wrong id — must NOT advance.
        try? await Task.sleep(nanoseconds: 350_000_000)
        #expect(recorder.count == 0)

        // Now our passage starts and finishes -> advance.
        state.status = .loading
        state.currentPassageId = "1"
        state.status = .stopped
        await waitUntil(timeout: 3) { recorder.count == 1 }
        #expect(recorder.count == 1)
        watcher.cancel()
    }

    @Test("bails on .error without advancing")
    func bailsOnError() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        state.status = .loading
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "0") { recorder.record() }

        state.status = .error
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 0)
        watcher.cancel()
    }

    @Test("cancel stops the watch so a later .stopped does not advance")
    func cancelStopsWatch() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        state.status = .loading
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "0") { recorder.record() }
        watcher.cancel()

        // The terminal state arrives AFTER cancellation — must be ignored.
        state.status = .stopped
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 0)
    }

    @Test("a fresh start supersedes the previous watch")
    func startSupersedesPreviousWatch() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        // Arm a watch on "0" but never satisfy it; restart targeting "1".
        watcher.start(targetPassageId: "0") { recorder.record() }
        state.status = .loading
        state.currentPassageId = "1"
        watcher.start(targetPassageId: "1") { recorder.record() }
        state.status = .stopped // matches "1"

        await waitUntil(timeout: 3) { recorder.count == 1 }
        // Exactly one advance — the superseded "0" watch was cancelled.
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.count == 1)
        watcher.cancel()
    }
}
