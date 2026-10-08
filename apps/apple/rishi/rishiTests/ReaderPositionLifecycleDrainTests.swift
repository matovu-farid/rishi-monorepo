import Testing
@testable import rishi

@Suite("Reader position lifecycle drain")
@MainActor
struct ReaderPositionLifecycleDrainTests {
    @Test("overlapping inactive/background/close drains share one finite grant, ended on expiration")
    func overlapAndExpiration() async {
        var grants = 0
        var ends = 0
        var expiration: (@MainActor () -> Void)?
        var continuation: CheckedContinuation<Void, Never>?
        var writes = 0
        let lifecycle = ReaderPositionLifecycleDrain { expired in
            grants += 1
            expiration = expired
            return { ends += 1 }
        }
        let first = Task {
            await lifecycle.flush {
                writes += 1
                await withCheckedContinuation { continuation = $0 }
                return .committed
            }
        }
        while continuation == nil { await Task.yield() }
        let overlap = Task { await lifecycle.flush { writes += 1; return .writeFailed } }
        await Task.yield()
        expiration?()
        expiration?()
        #expect(ends == 1)
        continuation?.resume()
        #expect(await first.value == .committed)
        #expect(await overlap.value == .committed)
        #expect(grants == 1)
        #expect(writes == 1)
        #expect(ends == 1)
        #expect(await lifecycle.flush { .writeFailed } == .writeFailed)
        #expect(grants == 2)
        #expect(ends == 2)
    }
}
