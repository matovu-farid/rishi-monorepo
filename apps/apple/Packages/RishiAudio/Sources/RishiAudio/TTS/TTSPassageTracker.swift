import Foundation
import Observation

/// Bridges `TTSPlaybackState.currentPassageId` (an `@Observable` on
/// `@MainActor`) into an `AsyncStream<String>` that the reader VM
/// extension (plan 08-06) can `for await` to drive the in-text highlight
/// (TTS-06).
///
/// Distinct-only — the same passage id is not re-emitted on a no-op
/// write. The reader VM extension owns the actual highlight rendering;
/// the tracker only signals "this passage just became current."
public actor TTSPassageTracker {

    private var observationTask: Task<Void, Never>?
    private var lastEmitted: String?
    private var continuation: AsyncStream<String>.Continuation?

    public init() {}

    deinit {
        observationTask?.cancel()
        continuation?.finish()
    }

    /// Begin polling `state.currentPassageId`. Light polling (50ms) is
    /// cheaper than re-arming `withObservationTracking` from an actor on
    /// every change; well under the TTSEngine's sentence-boundary
    /// cadence.
    public func attach(state: TTSPlaybackState) async {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                let current = await MainActor.run { state.currentPassageId }
                await self?.handle(current)
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms tick
            }
        }
    }

    public func detach() {
        observationTask?.cancel()
        observationTask = nil
        continuation?.finish()
        continuation = nil
    }

    /// AsyncStream of distinct, non-nil passage ids. Plan 08-06's reader
    /// VM extension `for await`s this to apply the in-text highlight.
    public func passageStream() -> AsyncStream<String> {
        AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearContinuation() }
            }
        }
    }

    private func clearContinuation() {
        continuation = nil
    }

    private func handle(_ passageId: String?) {
        guard let passageId else { return }
        guard passageId != lastEmitted else { return }
        lastEmitted = passageId
        continuation?.yield(passageId)
    }
}
