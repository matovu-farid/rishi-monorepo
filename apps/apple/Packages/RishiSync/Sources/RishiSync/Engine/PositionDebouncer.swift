import Foundation
import RishiCore

/// SYNC-03 debounce — per-bookId coalesce over a fixed window.
///
/// `mark(_:)` cancels any in-flight window for the bookId and starts a new
/// one. When the window expires without interruption, the registered
/// commit closure fires exactly once with that bookId.
///
/// `flush()` cancels every in-flight window and fires the commit closure
/// immediately for each pending bookId — the engine teardown path.
public actor PositionDebouncer {

    public typealias Commit = @Sendable (BookID) async -> Void

    private let window: TimeInterval
    private let commit: Commit
    private var tasks: [BookID: Task<Void, Never>] = [:]

    public init(window: TimeInterval, commit: @escaping Commit) {
        self.window = window
        self.commit = commit
    }

    /// Cancel any pending window for `bookId` and schedule a fresh one.
    public func mark(_ bookId: BookID) {
        tasks[bookId]?.cancel()
        let commit = self.commit
        let window = self.window
        tasks[bookId] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(window * 1_000_000_000))
            } catch {
                // Sleep cancelled — newer mark is in flight; bail.
                return
            }
            if Task.isCancelled { return }
            await commit(bookId)
            await self?.clear(bookId)
        }
    }

    /// Fire all pending commits immediately (engine shutdown / app background).
    public func flush() async {
        let snapshot = tasks
        tasks.removeAll()
        for (bookId, task) in snapshot {
            task.cancel()
            await commit(bookId)
        }
    }

    public func pendingCount() -> Int { tasks.count }

    private func clear(_ bookId: BookID) {
        tasks[bookId] = nil
    }
}
