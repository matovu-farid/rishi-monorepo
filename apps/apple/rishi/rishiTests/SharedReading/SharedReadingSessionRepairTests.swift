import Testing

@testable import rishi

@Suite("Shared reading session repair")
struct SharedReadingSessionRepairTests {
    private actor Counter {
        var attempts = 0
        var repairs = 0

        func attempt() { attempts += 1 }
        func repair() { repairs += 1 }
        func snapshot() -> (attempts: Int, repairs: Int) { (attempts, repairs) }
    }

    @Test("repairs a not-ready book once before retrying")
    func repairsAndRetriesOnce() async throws {
        let counter = Counter()

        let result = try await SharedReadingSessionCreation.create(
            operation: {
                await counter.attempt()
                let snapshot = await counter.snapshot()
                if snapshot.attempts == 1 {
                    throw SharedReadingError.from(code: .bookNotReady)
                }
                return "created"
            },
            repair: {
                await counter.repair()
                return true
            }
        )

        #expect(result == "created")
        let snapshot = await counter.snapshot()
        #expect(snapshot.attempts == 2)
        #expect(snapshot.repairs == 1)
    }

    @Test("does not retry when the repaired book is still not ready")
    func doesNotLoopOnSecondNotReady() async {
        let counter = Counter()

        await #expect(throws: SharedReadingError.self) {
            try await SharedReadingSessionCreation.create(
                operation: {
                    await counter.attempt()
                    throw SharedReadingError.from(code: .bookNotReady)
                },
                repair: {
                    await counter.repair()
                    return true
                }
            )
        }

        let snapshot = await counter.snapshot()
        #expect(snapshot.attempts == 2)
        #expect(snapshot.repairs == 1)
    }
}
