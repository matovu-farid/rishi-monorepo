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
/// log and waiter box, guarded by an `OSAllocatedUnfairLock` (mirrors
/// `FakeAudioEngine`). All `TTSPlaybackState` mutation hops to `@MainActor`
/// since the state object is main-actor-isolated.
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
        /// Drives the injected state to `.error` (sets `error`) with no
        /// `.playing`/`.stopped`. Used by 29-03 to assert the bridge bails
        /// (does not advance) when the engine reports a failure.
        case error
        /// Records a sticky typed allowance failure and never advances.
        case allowance(WorkerAllowanceError)
        /// `.loading` -> `.playing` (sets `currentPassageId`) and HOLDS there,
        /// never reaching `.stopped`, so the advance watcher never auto-advances.
        /// Used to test user-driven next()/previous() navigation deterministically
        /// (no auto-advance race).
        case holds
    }

    private let state: TTSPlaybackState
    private let defaultScript: Script
    /// Optional per-passage script overrides keyed by passage id, so a single
    /// fake can drive index 0 with `.normal` and indices >= 1 with
    /// `.prewarmedFast` (the prewarmed-fast-advance reproducer in 29-03).
    private let scriptsByPassageId: [String: Script]

    private let lock = OSAllocatedUnfairLock(initialState: [Call]())
    private let waiterBox = OSAllocatedUnfairLock(initialState: WaiterBox())

    public init(state: TTSPlaybackState, script: Script = .normal) {
        self.state = state
        self.defaultScript = script
        self.scriptsByPassageId = [:]
    }

    /// Per-passage scripting. `scriptsByPassageId[passageId]` wins for a request
    /// carrying that id; otherwise `default` is used. Enables the round-2
    /// reproducer where the FIRST paragraph is synthesis-bound (`.normal`) and
    /// every subsequent (prewarmed/cache-hit) paragraph runs its whole lifecycle
    /// inside one poll (`.prewarmedFast`).
    public init(
        state: TTSPlaybackState,
        default defaultScript: Script,
        scriptsByPassageId: [String: Script]
    ) {
        self.state = state
        self.defaultScript = defaultScript
        self.scriptsByPassageId = scriptsByPassageId
    }

    private func script(for passageId: String?) -> Script {
        if let passageId, let override = scriptsByPassageId[passageId] {
            return override
        }
        return defaultScript
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
        // Supersede any prior waiter before scripting a new lifecycle.
        failWaiterIfAny(CancellationError())
        clearPending()

        let observable = state
        let passageId = request.passageId
        switch script(for: passageId) {
        case .normal:
            await MainActor.run {
                observable.update(status: .loading)
                observable.error = nil
            }
            await MainActor.run {
                observable.update(status: .playing)
                observable.currentPassageId = passageId
            }
            await MainActor.run {
                observable.update(status: .stopped)
                // currentPassageId intentionally left SET through .stopped.
            }
            settle(.success(()))
        case .prewarmedFast:
            await MainActor.run {
                observable.update(status: .stopped)
                observable.currentPassageId = passageId
                observable.error = nil
            }
            settle(.failure(TTSEnginePlaybackError.finishedWithoutPlaying))
        case .error:
            await MainActor.run {
                observable.update(status: .error)
                observable.error = "FakeTTSEngine scripted error"
            }
            settle(.failure(TTSEnginePlaybackError.playbackFailed("FakeTTSEngine scripted error")))
        case .allowance(let failure):
            await MainActor.run {
                observable.recordTypedFailure(failure, tokens: request.tokenSnapshot)
            }
            settle(.failure(TTSEnginePlaybackError.playbackFailed(failure.message)))
        case .holds:
            await MainActor.run {
                observable.update(status: .loading)
                observable.error = nil
            }
            await MainActor.run {
                observable.update(status: .playing)
                observable.currentPassageId = passageId
                // Intentionally never transitions to .stopped: the advance
                // watcher waits, so only explicit next()/previous() move the head.
            }
            // Do not settle until stop().
        }
    }

    public func pause() async {
        append(.pause)
        let observable = state
        await MainActor.run { observable.update(status: .stopped) }
    }

    public func resume() async {
        append(.resume)
        let observable = state
        await MainActor.run { observable.update(status: .playing) }
    }

    public func stop() async {
        append(.stop)
        let observable = state
        await MainActor.run { observable.update(status: .stopped) }
        settle(.failure(CancellationError()))
    }

    public func waitUntilFinished() async throws {
        if let pending = takePending() {
            try pending.get()
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let action = waiterBox.withLock { box -> WaiterInstall in
                if let pending = box.pendingResult {
                    box.pendingResult = nil
                    return .resumeNow(pending)
                }
                if let existing = box.waiter {
                    box.waiter = continuation
                    return .replace(existing)
                }
                box.waiter = continuation
                return .installed
            }
            switch action {
            case .resumeNow(let result):
                continuation.resume(with: result)
            case .replace(let existing):
                existing.resume(throwing: CancellationError())
            case .installed:
                break
            }
        }
    }

    private func settle(_ result: Result<Void, Error>) {
        let toResume: CheckedContinuation<Void, Error>? = waiterBox.withLock { box in
            if let waiter = box.waiter {
                box.waiter = nil
                box.pendingResult = nil
                return waiter
            }
            box.pendingResult = result
            return nil
        }
        toResume?.resume(with: result)
    }

    private func failWaiterIfAny(_ error: Error) {
        let toResume: CheckedContinuation<Void, Error>? = waiterBox.withLock { box in
            let waiter = box.waiter
            box.waiter = nil
            return waiter
        }
        toResume?.resume(throwing: error)
    }

    private func clearPending() {
        waiterBox.withLock { $0.pendingResult = nil }
    }

    private func takePending() -> Result<Void, Error>? {
        waiterBox.withLock { box in
            let pending = box.pendingResult
            box.pendingResult = nil
            return pending
        }
    }

    private struct WaiterBox {
        var pendingResult: Result<Void, Error>?
        var waiter: CheckedContinuation<Void, Error>?
    }

    private enum WaiterInstall {
        case resumeNow(Result<Void, Error>)
        case replace(CheckedContinuation<Void, Error>)
        case installed
    }
}
