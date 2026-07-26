import Foundation
import os

/// Test fake conforming to `BookSearch`. Returns the staged hits / throws
/// the staged error / reports the staged status, regardless of the actual
/// query or book id. Records the most recent `queryText`, `bookId`, and
/// total call count so assertions can verify the wiring.
///
/// Usage shape mirrors Phase 10's `FakeRealtimeClient`: a `final class`
/// marked `@unchecked Sendable` because the public state is guarded by a
/// single `OSAllocatedUnfairLock`. The protocol's `search` / `status`
/// methods are `async` only because the protocol is, not because the
/// fake itself does any awaiting — every method completes synchronously.
///
/// Plan 25-07's `BookContextResponder` tests and Plan 25-09's voice-chat
/// integration tests both consume this fake via `import RishiSearch`.
public final class StubBookSearch: BookSearch, @unchecked Sendable {

    private struct State {
        var hits: [BookSearchHit] = []
        var status: BookSearchStatus = .ready
        var error: BookContextSearchError? = nil
        var searchCallCount: Int = 0
        var statusCallCount: Int = 0
        var lastQuery: String? = nil
        var lastBookId: UUID? = nil
    }

    private let lock: OSAllocatedUnfairLock<State>

    public init(hits: [BookSearchHit] = [], status: BookSearchStatus = .ready) {
        var seed = State()
        seed.hits = hits
        seed.status = status
        self.lock = OSAllocatedUnfairLock(initialState: seed)
    }

    // MARK: - Test drivers

    /// Replace the hit list returned by subsequent `search(...)` calls.
    public func setHits(_ hits: [BookSearchHit]) {
        lock.withLock { $0.hits = hits }
    }

    /// Replace the status returned by subsequent `status(bookId:)` calls.
    public func setStatus(_ status: BookSearchStatus) {
        lock.withLock { $0.status = status }
    }

    /// Stage an error that subsequent `search(...)` calls will throw.
    /// Pass `nil` to clear the error and resume returning staged hits.
    public func setError(_ error: BookContextSearchError?) {
        lock.withLock { $0.error = error }
    }

    // MARK: - Test inspection

    /// Total number of times `search(...)` has been called. Increments
    /// even when the call throws — the contract is "how often was the
    /// stub invoked", not "how often did it succeed".
    public func searchCallCount() -> Int {
        lock.withLock { $0.searchCallCount }
    }

    /// Total number of times `status(bookId:)` has been called.
    public func statusCallCount() -> Int {
        lock.withLock { $0.statusCallCount }
    }

    /// `queryText` from the most recent `search(...)` call, or `nil` if
    /// `search` has never been called.
    public func lastQuery() -> String? {
        lock.withLock { $0.lastQuery }
    }

    /// `bookId` from the most recent `search(...)` call, or `nil` if
    /// `search` has never been called.
    public func lastBookId() -> UUID? {
        lock.withLock { $0.lastBookId }
    }

    // MARK: - BookSearch

    public func search(queryText: String, bookId: UUID) async throws -> [BookSearchHit] {
        let snapshot: (error: BookContextSearchError?, hits: [BookSearchHit]) = lock.withLock { state in
            state.searchCallCount += 1
            state.lastQuery = queryText
            state.lastBookId = bookId
            return (state.error, state.hits)
        }
        if let err = snapshot.error { throw err }
        return snapshot.hits
    }

    public func status(bookId: UUID) async -> BookSearchStatus {
        lock.withLock { state in
            state.statusCallCount += 1
            return state.status
        }
    }
}
