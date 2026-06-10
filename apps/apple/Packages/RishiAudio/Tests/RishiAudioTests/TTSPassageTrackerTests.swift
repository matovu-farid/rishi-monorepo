import Testing
import Foundation
@testable import RishiAudio

@Suite("TTSPassageTracker", .serialized)
struct TTSPassageTrackerTests {

    @MainActor
    @Test("Yields distinct passage ids in order")
    func yieldsDistinct() async {
        let state = TTSPlaybackState()
        let tracker = TTSPassageTracker()
        let stream = await tracker.passageStream()
        await tracker.attach(state: state)

        let collector = Task<[String], Never> {
            var collected: [String] = []
            for await id in stream {
                collected.append(id)
                if collected.count == 2 { break }
            }
            return collected
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        state.currentPassageId = "p-1"
        try? await Task.sleep(nanoseconds: 200_000_000)
        state.currentPassageId = "p-1" // duplicate — should not re-yield
        try? await Task.sleep(nanoseconds: 100_000_000)
        state.currentPassageId = "p-2"
        let result = await collector.value
        #expect(result == ["p-1", "p-2"])
        await tracker.detach()
    }

    @MainActor
    @Test("detach() finishes the stream")
    func detachFinishes() async {
        let state = TTSPlaybackState()
        let tracker = TTSPassageTracker()
        let stream = await tracker.passageStream()
        await tracker.attach(state: state)

        let finished = Task<Bool, Never> {
            for await _ in stream {}
            return true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await tracker.detach()
        let didFinish = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask { await finished.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 500_000_000)
                return false
            }
            for await first in group {
                group.cancelAll()
                return first
            }
            return false
        }
        #expect(didFinish == true)
    }
}
