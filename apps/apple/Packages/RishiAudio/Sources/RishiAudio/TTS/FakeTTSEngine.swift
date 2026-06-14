import Foundation

#if canImport(os)
import os
#endif

/// Scriptable `TTSPlaying` fake (Phase 29, 29-RESEARCH §2). Drives an injected
/// `TTSPlaybackState` through status transitions with no audio render and no
/// network, so `ReaderTTSBridge`'s start/advance/stop/jump orchestration can be
/// tested deterministically.
///
/// `start(request:)` scripts the state the same way the real `TTSEngine` does as
/// a documented post-condition (per AdvanceWatcherDecision round 2): it sets
/// `currentPassageId` to the request's passage id and leaves it set through the
/// terminal `.stopped`, so a passage-identity-aware watcher can advance off
/// `(status == .stopped, currentPassageId == targetId)`.
///
/// `@unchecked Sendable` justified: the only mutable state is the ordered call
/// log, guarded by an `OSAllocatedUnfairLock` (mirrors `FakeAudioEngine`). All
/// `TTSPlaybackState` mutation hops to `@MainActor` since the state object is
/// main-actor-isolated.
public final class FakeTTSEngine: TTSPlaying, @unchecked Sendable {

    /// Ordered call log so plan 29-03 can assert call ordering (e.g. "old
    /// session torn down before the new start").
    public enum Call: Sendable, Equatable {
        case start(passageId: String?)
        case stop
        case pause
        case resume
    }

    /// How `start(request:)` drives the injected state.
    public enum Script: Sendable {
        /// `.loading` -> `.playing` (sets `currentPassageId`) -> `.stopped`,
        /// leaving `currentPassageId` SET through `.stopped` — matches the real
        /// engine's documented post-condition.
        case normal
        /// Short-prewarmed-paragraph race (RESEARCH §3.3): jumps straight to
        /// `.stopped` + `currentPassageId` in a single step with no observable
        /// `.loading` / `.playing`. Used by 29-03 to exercise the watcher's
        /// passage-identity fast path.
        case prewarmedFast
    }

    private let state: TTSPlaybackState
    private let script: Script

    private let lock = OSAllocatedUnfairLock(initialState: [Call]())

    public init(state: TTSPlaybackState, script: Script = .normal) {
        self.state = state
        self.script = script
    }

    /// Ordered log of every call made on this fake.
    public var calls: [Call] {
        lock.withLock { $0 }
    }

    private func append(_ call: Call) {
        lock.withLock { $0.append(call) }
    }

    public func start(request: TTSStreamRequest) async {
        append(.start(passageId: request.passageId))
        let observable = state
        let passageId = request.passageId
        switch script {
        case .normal:
            await MainActor.run {
                observable.status = .loading
                observable.error = nil
            }
            await MainActor.run {
                observable.status = .playing
                observable.currentPassageId = passageId
            }
            await MainActor.run {
                observable.status = .stopped
                // currentPassageId intentionally left SET through .stopped.
            }
        case .prewarmedFast:
            await MainActor.run {
                observable.status = .stopped
                observable.currentPassageId = passageId
                observable.error = nil
            }
        }
    }

    public func pause() async {
        append(.pause)
        let observable = state
        await MainActor.run { observable.status = .stopped }
    }

    public func resume() async {
        append(.resume)
        let observable = state
        await MainActor.run { observable.status = .playing }
    }

    public func stop() async {
        append(.stop)
        let observable = state
        await MainActor.run { observable.status = .stopped }
    }
}
