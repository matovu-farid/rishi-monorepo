@testable import rishi
import Foundation
import Testing

@Suite("ChapterIndexGenerationDispatcher")
struct ChapterIndexGenerationDispatcherTests {
    @Test("holds requests before configuration and drains each book once")
    func drainsPendingRequestsOnce() async {
        let dispatcher = ChapterIndexGenerationDispatcher()
        let firstBook = UUID()
        let secondBook = UUID()
        let lock = TestIDLock()

        await dispatcher.schedule(firstBook)
        await dispatcher.schedule(firstBook)
        await dispatcher.schedule(secondBook)

        await dispatcher.configure { id in
            await lock.append(id)
        }
        await eventually { await lock.count() == 2 }

        let values = await lock.values()
        #expect(Set(values) == Set([firstBook, secondBook]))
    }

    @Test("does not run the same book concurrently")
    func deduplicatesWhileRunning() async {
        let dispatcher = ChapterIndexGenerationDispatcher()
        let bookID = UUID()
        let state = TestDispatcherState()

        await dispatcher.configure { _ in
            await state.started()
            try? await Task.sleep(for: .milliseconds(50))
            await state.finished()
        }
        await dispatcher.schedule(bookID)
        await dispatcher.schedule(bookID)
        await eventually { await state.finishedCount() == 1 }

        #expect(await state.startedCount() == 1)
    }

    @Test("run waits for scheduled generation to finish")
    func runAwaitsScheduledWork() async {
        let dispatcher = ChapterIndexGenerationDispatcher()
        let state = TestDispatcherState()
        await dispatcher.configure { _ in
            await state.started()
            try? await Task.sleep(for: .milliseconds(50))
            await state.finished()
        }

        await dispatcher.run([UUID()])

        #expect(await state.finishedCount() == 1)
    }

    @Test("refresh queues one follow-up after the current generation")
    func refreshQueuesFollowUp() async {
        let dispatcher = ChapterIndexGenerationDispatcher()
        let state = TestDispatcherState()
        await dispatcher.configure { _ in
            await state.started()
            try? await Task.sleep(for: .milliseconds(25))
            await state.finished()
        }

        await dispatcher.schedule(UUID())
        let bookID = UUID()
        await dispatcher.schedule(bookID)
        await dispatcher.refresh(bookID)
        await dispatcher.run([bookID])

        #expect(await state.startedCount() == 3)
        #expect(await state.finishedCount() == 3)
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor TestIDLock {
    private var ids: [UUID] = []
    func append(_ id: UUID) { ids.append(id) }
    func values() -> [UUID] { ids }
    func count() -> Int { ids.count }
}

private actor TestDispatcherState {
    private var starts = 0
    private var finishes = 0
    func started() { starts += 1 }
    func finished() { finishes += 1 }
    func startedCount() -> Int { starts }
    func finishedCount() -> Int { finishes }
}
