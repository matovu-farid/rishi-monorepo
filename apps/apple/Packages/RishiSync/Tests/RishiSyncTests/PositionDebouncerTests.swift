import Testing
import Foundation
@testable import RishiSync
import RishiCore

/// SYNC-03 — `PositionDebouncer` coalesces N rapid markDirty calls per bookId
/// into ONE commit fired after a fixed window.
@Suite("PositionDebouncer — per-bookId 1s coalesce", .serialized)
struct PositionDebouncerTests {

    /// Lock-guarded counter so the @Sendable commit closure stays Sendable.
    private final class CommitRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [BookID] = []

        func record(_ id: BookID) {
            lock.lock(); defer { lock.unlock() }
            calls.append(id)
        }

        func snapshot() -> [BookID] {
            lock.lock(); defer { lock.unlock() }
            return calls
        }
    }

    @Test("5 rapid marks for same bookId within window → 1 commit")
    func rapidMarksCollapseToOne() async throws {
        let recorder = CommitRecorder()
        let debouncer = PositionDebouncer(window: 0.15) { id in
            recorder.record(id)
        }
        let bookId = UUID()
        for _ in 0..<5 {
            await debouncer.mark(bookId)
            try await Task.sleep(nanoseconds: 5_000_000) // 5ms — well under the 150ms window
        }
        // Wait for the window to fire.
        try await Task.sleep(nanoseconds: 300_000_000) // 300ms
        let calls = recorder.snapshot()
        #expect(calls == [bookId])
    }

    @Test("Distinct bookIds → each gets its own window")
    func distinctBookIdsCommitIndependently() async throws {
        let recorder = CommitRecorder()
        let debouncer = PositionDebouncer(window: 0.1) { id in
            recorder.record(id)
        }
        let a = UUID()
        let b = UUID()
        await debouncer.mark(a)
        await debouncer.mark(b)
        try await Task.sleep(nanoseconds: 250_000_000) // 250ms
        let calls = Set(recorder.snapshot())
        #expect(calls == Set([a, b]))
    }

    @Test("flush() fires all pending windows immediately")
    func flushFiresPendingImmediately() async throws {
        let recorder = CommitRecorder()
        let debouncer = PositionDebouncer(window: 60.0) { id in
            recorder.record(id)
        }
        let a = UUID()
        let b = UUID()
        await debouncer.mark(a)
        await debouncer.mark(b)
        // Window is 60s but flush should not wait for it.
        await debouncer.flush()
        let calls = Set(recorder.snapshot())
        #expect(calls == Set([a, b]))
        let pending = await debouncer.pendingCount()
        #expect(pending == 0)
    }
}
