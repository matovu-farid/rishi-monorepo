import Foundation

/// Serializes owner lifecycle operations while preserving MainActor access to
/// controllers. Generation checks inside the owner still invalidate a queued
/// operation whose caller was superseded.
@MainActor
final class PlaybackLifecycleQueue {
    private var tail: Task<Void, Never>?

    func enqueue<T: Sendable>(_ operation: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let current = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        tail = Task { _ = await current.value; return () }
        return await current.value
    }
}
