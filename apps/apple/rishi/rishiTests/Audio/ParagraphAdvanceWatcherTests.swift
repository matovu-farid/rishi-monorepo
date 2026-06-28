import Foundation
import RishiAudio
import Testing

@testable import rishi

@Suite("ParagraphAdvanceWatcher")
@MainActor
struct ParagraphAdvanceWatcherTests {

    @MainActor
    final class AdvanceRecorder {
        private(set) var count = 0
        func record() { count += 1 }
    }

    private func waitUntil(timeout: TimeInterval, _ predicate: () -> Bool) async
    {
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

        state.update(status: .loading)
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "0") { recorder.record() }

        state.update(status: .stopped)

        await waitUntil(timeout: 3) { recorder.count == 1 }
        #expect(recorder.count == 1)

        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(recorder.count == 1)
        watcher.cancel()
    }

    @Test("does not advance off a residual .stopped for a different passage")
    func ignoresResidualStoppedForDifferentPassage() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        state.update(status: .stopped)
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "1") { recorder.record() }

        try? await Task.sleep(nanoseconds: 350_000_000)
        #expect(recorder.count == 0)

        state.update(status: .loading)
        state.currentPassageId = "1"
        state.update(status: .stopped)
        await waitUntil(timeout: 3) { recorder.count == 1 }
        #expect(recorder.count == 1)
        watcher.cancel()
    }

    @Test("bails on .error without advancing")
    func bailsOnError() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        state.update(status: .loading)
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "0") { recorder.record() }

        state.update(status: .error)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 0)
        watcher.cancel()
    }

    @Test("cancel stops the watch so a later .stopped does not advance")
    func cancelStopsWatch() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        state.update(status: .loading)
        state.currentPassageId = "0"
        watcher.start(targetPassageId: "0") { recorder.record() }
        watcher.cancel()

        state.update(status: .stopped)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(recorder.count == 0)
    }

    @Test("a fresh start supersedes the previous watch")
    func startSupersedesPreviousWatch() async {
        let state = TTSPlaybackState()
        let watcher = ParagraphAdvanceWatcher(state: state)
        let recorder = AdvanceRecorder()

        watcher.start(targetPassageId: "0") { recorder.record() }
        state.update(status: .loading)
        state.currentPassageId = "1"
        watcher.start(targetPassageId: "1") { recorder.record() }
        state.update(status: .stopped)

        await waitUntil(timeout: 3) { recorder.count == 1 }

        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(recorder.count == 1)
        watcher.cancel()
    }
}
